"""GitHub commits stream (GraphQL, incremental, partitioned by repo+branch)."""

import json
import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

import requests as req

from source_github.clients.auth import rest_headers
from source_github.graphql.queries import BULK_COMMIT_QUERY
from source_github.streams.base import GitHubGraphQLStream, _make_unique_key
from source_github.streams.branches import BranchesStream

logger = logging.getLogger("airbyte")


class CommitsStream(GitHubGraphQLStream):
    """Fetches commits via GraphQL bulk query, partitioned by repo+branch.

    Performance optimizations:
    - Repo freshness gate: skip repos where pushed_at hasn't changed
    - HEAD SHA tracking: skip branches where HEAD hasn't moved
    - Early exit: stop paginating when reaching previously-seen HEAD
    - Branch HEAD dedup: skip branches sharing same HEAD SHA
    - Branch compare: skip non-default branches with 0 commits ahead
    """

    name = "commits"
    cursor_field = "committed_date"
    # No use_cache — file_changes reads commits via read_records (no cache needed)

    def __init__(
        self,
        parent: BranchesStream,
        page_size: int = 100,
        start_date: Optional[str] = None,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._parent = parent
        self._page_size = page_size
        self._start_date = start_date
        self._partitions_with_errors: set = set()
        self._current_skipped_siblings: list = []
        self._current_stop_at_sha: Optional[str] = None

    def _query(self) -> str:
        return BULK_COMMIT_QUERY

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        if stream_slice is None:
            # Called by child stream (commit_files) — no cache, re-fetches
            for branch_slice in self.stream_slices(stream_state=stream_state):
                yield from super().read_records(
                    sync_mode=sync_mode, stream_slice=branch_slice, stream_state=stream_state, **kwargs
                )
        else:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice, stream_state=stream_state, **kwargs
            )

    def _variables(self, stream_slice=None, next_page_token=None) -> dict:
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        branch = s.get("branch", "")
        if not owner or not repo or not branch:
            raise ValueError(f"CommitsStream._variables() called with incomplete slice: owner={owner}, repo={repo}, branch={branch}")
        variables = {
            "owner": owner,
            "repo": repo,
            "branch": f"refs/heads/{branch}",
            "first": self._page_size,
        }
        if next_page_token and "after" in next_page_token:
            variables["after"] = next_page_token["after"]
        # Use cursor from state or start_date for initial run
        since = s.get("cursor_value") or self._start_date
        if since:
            variables["since"] = since
        return variables

    def _extract_nodes(self, data: dict) -> list:
        try:
            return (
                data.get("repository", {})
                .get("ref", {})
                .get("target", {})
                .get("history", {})
                .get("nodes", [])
            )
        except (AttributeError, TypeError):
            return []

    def _extract_page_info(self, data: dict) -> dict:
        try:
            return (
                data.get("repository", {})
                .get("ref", {})
                .get("target", {})
                .get("history", {})
                .get("pageInfo", {})
            )
        except (AttributeError, TypeError):
            return {}

    def next_page_token(self, response, **kwargs):
        """Override to stop pagination when we hit the previously-seen HEAD."""
        if self._current_stop_at_sha:
            # Check if any node on this page matches the stop SHA
            body = response.json()
            data = body.get("data", {})
            nodes = self._extract_nodes(data)
            for node in nodes:
                if node.get("oid") == self._current_stop_at_sha:
                    logger.debug(f"Early exit: reached known HEAD {self._current_stop_at_sha[:8]}")
                    return None

        return super().next_page_token(response, **kwargs)

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}

        # Collect all branches per repo
        repo_branches: dict[tuple, list] = {}
        for record in self._parent.read_records(sync_mode=None):
            owner = record.get("repo_owner", "")
            repo = record.get("repo_name", "")
            if owner and repo:
                repo_branches.setdefault((owner, repo), []).append(record)

        repos_skipped_fresh = 0
        branches_skipped_head = 0
        branches_skipped_not_ahead = 0

        for (owner, repo), branches in repo_branches.items():

            # --- Optimization 1: Repo freshness gate ---
            repo_pushed_at = ""
            for record in branches:
                pa = record.get("pushed_at", "")
                if pa:
                    repo_pushed_at = pa
                    break

            repo_state_key = f"_repo:{owner}/{repo}"
            stored_pushed_at = state.get(repo_state_key, {}).get("pushed_at", "")
            if repo_pushed_at and stored_pushed_at and repo_pushed_at <= stored_pushed_at:
                repos_skipped_fresh += 1
                logger.info(f"Repo freshness: skipping {owner}/{repo} (pushed_at unchanged: {repo_pushed_at})")
                continue

            # --- Find default branch ---
            default_branch = ""
            for record in branches:
                db = record.get("default_branch_name", "")
                if db:
                    default_branch = db
                    break

            # --- Optimization 2: Branch HEAD dedup ---
            def _sort_key(r, db=default_branch):
                return 0 if r.get("name") == db else 1

            seen_heads: dict[str, str] = {}
            skipped_map: dict[str, str] = {}
            selected = []
            for record in sorted(branches, key=_sort_key):
                branch = record.get("name", "")
                head_sha = (record.get("commit") or {}).get("sha", "")

                if not head_sha:
                    selected.append(record)
                    continue

                if head_sha in seen_heads:
                    skipped_map[branch] = seen_heads[head_sha]
                    continue

                seen_heads[head_sha] = branch
                selected.append(record)

            if skipped_map:
                logger.info(
                    f"Branch dedup: {owner}/{repo} — {len(selected)} of {len(branches)} branches "
                    f"selected, {len(skipped_map)} skipped (duplicate HEAD SHAs)"
                )

            # --- Optimization 3: HEAD SHA unchanged → skip branch ---
            # --- Optimization 4: Branch not ahead of default → skip ---
            final_selected = []
            default_head_sha = ""
            for record in selected:
                if record.get("name") == default_branch:
                    default_head_sha = (record.get("commit") or {}).get("sha", "")
                    break

            for record in selected:
                branch = record.get("name", "")
                head_sha = (record.get("commit") or {}).get("sha", "")
                partition_key = f"{owner}/{repo}/{branch}"
                stored = state.get(partition_key, {})
                stored_head = stored.get("head_sha", "")

                # HEAD SHA unchanged → skip entirely
                if head_sha and stored_head and head_sha == stored_head:
                    branches_skipped_head += 1
                    logger.debug(f"HEAD unchanged: skipping {owner}/{repo}/{branch} (HEAD {head_sha[:8]})")
                    continue

                # Non-default branch: check if ahead of default
                if (branch != default_branch and default_head_sha and head_sha
                        and head_sha != default_head_sha):
                    ahead = self._check_branch_ahead(owner, repo, default_branch, branch)
                    if ahead == 0:
                        branches_skipped_not_ahead += 1
                        logger.debug(f"Not ahead: skipping {owner}/{repo}/{branch} (0 commits ahead of {default_branch})")
                        # Persist HEAD so unchanged-HEAD gate skips this branch next sync
                        if head_sha:
                            state[partition_key] = {
                                **state.get(partition_key, {}),
                                "head_sha": head_sha,
                            }
                        continue

                final_selected.append((record, head_sha, stored_head))

            if branches_skipped_head or branches_skipped_not_ahead:
                logger.info(
                    f"Branch optimization: {owner}/{repo} — {len(final_selected)} branches to fetch, "
                    f"{branches_skipped_head} skipped (HEAD unchanged), "
                    f"{branches_skipped_not_ahead} skipped (not ahead of default)"
                )
                branches_skipped_head = 0
                branches_skipped_not_ahead = 0

            for record, head_sha, stored_head in final_selected:
                branch = record.get("name", "")
                partition_key = f"{owner}/{repo}/{branch}"
                cursor_value = state.get(partition_key, {}).get(self.cursor_field)

                # Force-push detection: if HEAD changed, the timestamp cursor
                # is unreliable (rewritten commits may have older dates).
                # Fall back to start_date so we re-fetch the full branch,
                # using stop_at_sha for early exit on unchanged commits.
                head_changed = stored_head and head_sha and head_sha != stored_head
                if head_changed and cursor_value:
                    logger.info(
                        f"HEAD changed on {owner}/{repo}/{branch} "
                        f"({stored_head[:8]}→{head_sha[:8]}): resetting cursor for re-fetch"
                    )
                    cursor_value = None  # will fall back to start_date in _variables()

                yield {
                    "owner": owner,
                    "repo": repo,
                    "branch": branch,
                    "default_branch": default_branch,
                    "partition_key": partition_key,
                    "cursor_value": cursor_value,
                    "head_sha": head_sha,
                    "stop_at_sha": stored_head,
                    "repo_pushed_at": repo_pushed_at,
                    "_skipped_siblings": [
                        f"{owner}/{repo}/{sb}" for sb, chosen in skipped_map.items()
                        if chosen == branch
                    ],
                }

    def _check_branch_ahead(self, owner: str, repo: str, base: str, head: str) -> int:
        """Check how many commits head branch is ahead of base. Returns ahead_by count."""
        try:
            self._rate_limiter.throttle("rest")
            resp = req.get(
                f"https://api.github.com/repos/{owner}/{repo}/compare/{base}...{head}",
                headers=rest_headers(self._token),
                timeout=15,
            )
            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            self._rate_limiter.wait_if_needed("rest")

            if resp.status_code != 200:
                return -1  # Unknown, don't skip
            return resp.json().get("ahead_by", -1)
        except (req.RequestException, json.JSONDecodeError, ValueError, KeyError):
            return -1  # On error, don't skip

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = f"{latest_record.get('repo_owner', '')}/{latest_record.get('repo_name', '')}/{latest_record.get('branch_name', '')}"
        if partition_key in self._partitions_with_errors:
            return current_stream_state
        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(self.cursor_field, "")
        if record_cursor > current_cursor:
            # Store both timestamp cursor AND head SHA
            head_sha = latest_record.get("head_sha", "")
            cursor_entry = {self.cursor_field: record_cursor}
            if head_sha:
                cursor_entry["head_sha"] = head_sha
            current_stream_state[partition_key] = cursor_entry
            # Mirror to skipped siblings
            for sibling_key in self._current_skipped_siblings:
                sibling_cursor = current_stream_state.get(sibling_key, {}).get(self.cursor_field, "")
                if record_cursor > sibling_cursor:
                    current_stream_state[sibling_key] = dict(cursor_entry)

        # Store repo pushed_at for freshness gate
        repo_pushed_at = latest_record.get("repo_pushed_at", "")
        if repo_pushed_at:
            owner = latest_record.get("repo_owner", "")
            repo = latest_record.get("repo_name", "")
            repo_state_key = f"_repo:{owner}/{repo}"
            current_stream_state[repo_state_key] = {"pushed_at": repo_pushed_at}

        return current_stream_state

    def parse_response(self, response, stream_slice=None, **kwargs):
        s = stream_slice or {}
        self._current_skipped_siblings = s.get("_skipped_siblings", [])
        self._current_stop_at_sha = s.get("stop_at_sha")
        head_sha = s.get("head_sha", "")
        repo_pushed_at = s.get("repo_pushed_at", "")
        default_branch = s.get("default_branch", "")

        body = response.json()
        self._update_graphql_rate_limit(body, response)
        self._rate_limiter.wait_if_needed("graphql")

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(f"GraphQL query failed: {body['errors']}")
            logger.warning(f"GraphQL partial errors (emitting data, freezing cursor): {body['errors']}")
            partition_key = f"{s.get('owner', '')}/{s.get('repo', '')}/{s.get('branch', '')}"
            self._partitions_with_errors.add(partition_key)

        data = body.get("data", {})
        nodes = self._extract_nodes(data)
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        branch = s.get("branch", "")

        for node in nodes:
            commit_hash = node.get("oid", "")

            # Early exit: stop at previously-seen HEAD
            if self._current_stop_at_sha and commit_hash == self._current_stop_at_sha:
                logger.debug(f"Early exit: reached known commit {commit_hash[:8]} on {owner}/{repo}/{branch}")
                return

            author = node.get("author") or {}
            author_user = author.get("user") or {}
            committer = node.get("committer") or {}
            committer_user = committer.get("user") or {}

            record = {
                "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, commit_hash),
                "oid": commit_hash,
                "message": node.get("message"),
                "committed_date": node.get("committedDate"),
                "authored_date": node.get("authoredDate"),
                "additions": node.get("additions"),
                "deletions": node.get("deletions"),
                "changed_files": node.get("changedFilesIfAvailable"),
                "author_name": author.get("name"),
                "author_email": author.get("email"),
                "author_login": author_user.get("login"),
                "author_database_id": author_user.get("databaseId"),
                "committer_name": committer.get("name"),
                "committer_email": committer.get("email"),
                "committer_login": committer_user.get("login"),
                "committer_database_id": committer_user.get("databaseId"),
                "parent_hashes": [p["oid"] for p in (node.get("parents", {}).get("nodes") or [])],
                "repo_owner": owner,
                "repo_name": repo,
                "branch_name": branch,
                "default_branch_name": default_branch,
                "head_sha": head_sha,
                "repo_pushed_at": repo_pushed_at,
            }
            yield self._add_envelope(record)

    def get_json_schema(self) -> Mapping[str, Any]:
        return {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "tenant_id": {"type": "string"},
                "source_id": {"type": "string"},
                "unique_key": {"type": "string"},
                "data_source": {"type": "string"},
                "collected_at": {"type": "string"},
                "oid": {"type": "string"},
                "message": {"type": ["null", "string"]},
                "committed_date": {"type": ["null", "string"]},
                "authored_date": {"type": ["null", "string"]},
                "additions": {"type": ["null", "integer"]},
                "deletions": {"type": ["null", "integer"]},
                "changed_files": {"type": ["null", "integer"]},
                "author_name": {"type": ["null", "string"]},
                "author_email": {"type": ["null", "string"]},
                "author_login": {"type": ["null", "string"]},
                "author_database_id": {"type": ["null", "integer"]},
                "committer_name": {"type": ["null", "string"]},
                "committer_email": {"type": ["null", "string"]},
                "committer_login": {"type": ["null", "string"]},
                "committer_database_id": {"type": ["null", "integer"]},
                "parent_hashes": {"type": ["null", "array"], "items": {"type": "string"}},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
                "branch_name": {"type": "string"},
                "default_branch_name": {"type": ["null", "string"]},
            },
        }

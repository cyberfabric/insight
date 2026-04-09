"""GitHub commits stream (GraphQL, incremental, partitioned by repo+branch)."""

import atexit
import logging
import os
import tempfile
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_github_v2.queries import BULK_COMMIT_QUERY
from source_github_v2.streams.base import GitHubGraphQLStream, _make_unique_key
from source_github_v2.streams.branches import BranchesStream

logger = logging.getLogger("airbyte")


class CommitsStream(GitHubGraphQLStream):
    """Fetches commits via GraphQL bulk query, partitioned by repo+branch.

    Performance optimizations (all in stream_slices, single-threaded):
    1. Repo freshness gate: skip repos where pushed_at hasn't changed
    2. Branch HEAD SHA dedup: skip sibling branches with same HEAD SHA
    3. HEAD SHA unchanged: skip branches where HEAD hasn't moved
    4. Seen-hash skip: skip non-default branches whose HEAD is in main's history
    5. Force-push detection: reset cursor when HEAD changes
    """

    name = "commits"
    cursor_field = "committed_date"

    def __init__(
        self,
        parent: BranchesStream,
        start_date: Optional[str] = None,
        page_size: int = 100,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._parent = parent
        self._start_date = start_date
        self._page_size = page_size
        self._partitions_with_errors: set = set()
        self._current_skipped_siblings: list = []
        self._current_stop_at_sha: Optional[str] = None
        self._last_partition_key: Optional[str] = None
        self._stop_pagination: bool = False
        self._seen_hashes: dict[str, str] = {}  # sha → "owner/repo"
        self._deferred_state_updates: dict[str, dict] = {}  # partition_key → state entry
        # Temp file for passing commit metadata to file_changes (near-zero memory).
        self._commit_meta_file = tempfile.NamedTemporaryFile(
            mode="w", prefix="insight_commits_meta_", suffix=".tsv", delete=False,
        )
        self._commit_meta_path = self._commit_meta_file.name
        atexit.register(lambda p=self._commit_meta_path: os.unlink(p) if os.path.exists(p) else None)
        self._commit_meta_count: int = 0
        logger.info(f"Commit metadata temp file: {self._commit_meta_path}")

    def _query(self) -> str:
        return BULK_COMMIT_QUERY

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        if stream_slice is None:
            for branch_slice in self.stream_slices(stream_state=stream_state):
                yield from super().read_records(
                    sync_mode=sync_mode, stream_slice=branch_slice,
                    stream_state=stream_state, **kwargs,
                )
        else:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice,
                stream_state=stream_state, **kwargs,
            )

    def _variables(self, stream_slice=None, next_page_token=None) -> dict:
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        branch = s.get("branch", "")
        if not owner or not repo or not branch:
            raise ValueError(
                f"CommitsStream._variables() called with incomplete slice: "
                f"owner={owner}, repo={repo}, branch={branch}"
            )
        variables: dict[str, Any] = {
            "owner": owner,
            "repo": repo,
            "branch": f"refs/heads/{branch}",
            "first": self._page_size,
        }
        if next_page_token and "after" in next_page_token:
            variables["after"] = next_page_token["after"]
        since = s.get("cursor_value") or self._start_date
        if since:
            if len(since) == 10:
                since = f"{since}T00:00:00Z"
            variables["since"] = since
        return variables

    def _extract_nodes(self, data: dict) -> list:
        return self._safe_get(data, "repository", "ref", "target", "history", "nodes") or []

    def _extract_page_info(self, data: dict) -> dict:
        return self._safe_get(data, "repository", "ref", "target", "history", "pageInfo") or {}

    def next_page_token(self, response, **kwargs):
        """Override to stop pagination on dedup exit or previously-seen HEAD."""
        # parse_response signals stop via this flag (dedup exit, stop_at_sha hit)
        if self._stop_pagination:
            self._stop_pagination = False
            return None

        if self._current_stop_at_sha:
            body = response.json()
            data = body.get("data", {})
            nodes = self._extract_nodes(data)
            for node in nodes:
                if node.get("oid") == self._current_stop_at_sha:
                    logger.debug(f"Early exit: reached known HEAD {self._current_stop_at_sha[:8]}")
                    return None

        return super().next_page_token(response, **kwargs)

    # ------------------------------------------------------------------
    # stream_slices: all branch-level optimizations live here
    # ------------------------------------------------------------------

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}

        # Group all branches by repo
        repo_branches: dict[tuple, list] = {}
        for record in self._parent.get_child_records():
            owner = record.get("repo_owner", "")
            repo = record.get("repo_name", "")
            if owner and repo:
                repo_branches.setdefault((owner, repo), []).append(record)

        repos_skipped_fresh = 0
        branches_skipped_head = 0

        for (owner, repo), branches in repo_branches.items():
            # Bound memory: dedup is per-repo (cross-branch), not cross-repo
            self._seen_hashes.clear()

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
                db = record.get("default_branch", "")
                if db:
                    default_branch = db
                    break

            # --- Optimization 2: Branch HEAD SHA dedup ---
            def _sort_key(r, db=default_branch):
                return 0 if r.get("name") == db else 1

            seen_heads: dict[str, str] = {}
            skipped_map: dict[str, str] = {}
            selected: list = []
            for record in sorted(branches, key=_sort_key):
                branch_name = record.get("name", "")
                head_sha = (record.get("commit") or {}).get("sha", "")

                if not head_sha:
                    selected.append(record)
                    continue

                if head_sha in seen_heads:
                    skipped_map[branch_name] = seen_heads[head_sha]
                    continue

                seen_heads[head_sha] = branch_name
                selected.append(record)

            if skipped_map:
                logger.info(
                    f"Branch dedup: {owner}/{repo} - {len(selected)} of {len(branches)} branches "
                    f"selected, {len(skipped_map)} skipped (duplicate HEAD SHAs)"
                )

            # --- Optimization 3: HEAD SHA unchanged -> skip branch ---
            final_selected: list[tuple] = []
            for record in selected:
                branch_name = record.get("name", "")
                head_sha = (record.get("commit") or {}).get("sha", "")
                partition_key = f"{owner}/{repo}/{branch_name}"
                stored = state.get(partition_key, {})
                stored_head = stored.get("head_sha", "")

                # HEAD SHA unchanged -> skip entirely
                if head_sha and stored_head and head_sha == stored_head:
                    branches_skipped_head += 1
                    logger.debug(f"HEAD unchanged: skipping {partition_key} (HEAD {head_sha[:8]})")
                    continue

                final_selected.append((record, head_sha, stored_head))

            if branches_skipped_head:
                logger.info(
                    f"Branch optimization: {owner}/{repo} - {len(final_selected)} branches to fetch, "
                    f"{branches_skipped_head} skipped (HEAD unchanged)"
                )
                branches_skipped_head = 0

            # --- Optimization 4: Seen-hash skip for non-default branches ---
            branches_skipped_seen = 0
            for record, head_sha, stored_head in final_selected:
                branch_name = record.get("name", "")

                # After default branch is processed, _seen_hashes is populated.
                # Skip non-default branches whose HEAD is already in main's history.
                if branch_name != default_branch and head_sha and head_sha in self._seen_hashes:
                    branches_skipped_seen += 1
                    # Defer head_sha update — applied in get_updated_state (don't mutate state dict)
                    partition_key = f"{owner}/{repo}/{branch_name}"
                    if head_sha:
                        self._deferred_state_updates[partition_key] = {
                            **state.get(partition_key, {}),
                            "head_sha": head_sha,
                        }
                    continue

                partition_key = f"{owner}/{repo}/{branch_name}"
                cursor_value = state.get(partition_key, {}).get(self.cursor_field)

                # Optimization 5: Force-push detection
                head_changed = stored_head and head_sha and head_sha != stored_head
                if head_changed and cursor_value:
                    logger.info(
                        f"HEAD changed on {partition_key} "
                        f"({stored_head[:8]}->{head_sha[:8]}): resetting cursor for re-fetch"
                    )
                    cursor_value = None  # falls back to start_date in _variables()

                yield {
                    "owner": owner,
                    "repo": repo,
                    "branch": branch_name,
                    "default_branch": default_branch,
                    "partition_key": partition_key,
                    "cursor_value": cursor_value,
                    "head_sha": head_sha,
                    "stop_at_sha": stored_head,
                    "repo_pushed_at": repo_pushed_at,
                    "_skipped_siblings": [
                        f"{owner}/{repo}/{sb}"
                        for sb, chosen in skipped_map.items()
                        if chosen == branch_name
                    ],
                }

            if branches_skipped_seen:
                logger.info(
                    f"Seen-hash skip: {owner}/{repo} - {branches_skipped_seen} non-default branches "
                    f"skipped (HEAD already in default branch history)"
                )

    # ------------------------------------------------------------------
    # parse_response
    # ------------------------------------------------------------------

    def parse_response(self, response, stream_slice=None, **kwargs):
        s = stream_slice or {}
        self._current_skipped_siblings = s.get("_skipped_siblings", [])
        self._current_stop_at_sha = s.get("stop_at_sha")
        head_sha = s.get("head_sha", "")
        repo_pushed_at = s.get("repo_pushed_at", "")
        default_branch = s.get("default_branch", "")

        partition_key = f"{s.get('owner', '')}/{s.get('repo', '')}/{s.get('branch', '')}"
        if partition_key != self._last_partition_key:
            self._partitions_with_errors.discard(self._last_partition_key)
            self._last_partition_key = partition_key

        body = response.json()
        self._update_graphql_rate_limit(body, response)

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(f"GraphQL query failed: {body['errors']}")
            logger.warning(f"GraphQL partial errors (emitting data, freezing cursor): {body['errors']}")
            self._partitions_with_errors.add(partition_key)

        data = body.get("data", {})
        nodes = self._extract_nodes(data)
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        branch = s.get("branch", "")

        hit_seen = False
        for node in nodes:
            commit_hash = node.get("oid", "")

            # Early exit: stop at previously-seen HEAD
            if self._current_stop_at_sha and commit_hash == self._current_stop_at_sha:
                logger.debug(f"Early exit: reached known commit {commit_hash[:8]} on {owner}/{repo}/{branch}")
                self._stop_pagination = True
                return

            # Dedup: skip commits already seen from earlier branches
            if commit_hash in self._seen_hashes:
                hit_seen = True
                continue
            self._seen_hashes[commit_hash] = f"{owner}/{repo}"

            author = node.get("author") or {}
            author_user = author.get("user") or {}
            committer = node.get("committer") or {}
            committer_user = committer.get("user") or {}

            record = {
                "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, commit_hash),
                "sha": commit_hash,
                "message": node.get("message"),
                "committed_date": node.get("committedDate"),
                "authored_date": node.get("authoredDate"),
                "additions": node.get("additions"),
                "deletions": node.get("deletions"),
                "changed_files": node.get("changedFilesIfAvailable"),
                "author_name": author.get("name"),
                "author_email": author.get("email"),
                "author_login": author_user.get("login"),
                "author_id": author_user.get("databaseId"),
                "committer_name": committer.get("name"),
                "committer_email": committer.get("email"),
                "committer_login": committer_user.get("login"),
                "committer_id": committer_user.get("databaseId"),
                "parent_hashes": [p["oid"] for p in (node.get("parents", {}).get("nodes") or [])],
                "repo_owner": owner,
                "repo_name": repo,
                "branch_name": branch,
                "default_branch_name": default_branch,
                "head_sha": head_sha,
                "repo_pushed_at": repo_pushed_at,
            }
            yield self._add_envelope(record)

            # Write metadata row for file_changes stream (TSV, disk-backed)
            parent_count = len(record["parent_hashes"]) if record.get("parent_hashes") else 0
            self._commit_meta_file.write(
                f"{commit_hash}\t{owner}\t{repo}\t{node.get('committedDate', '')}\t{parent_count}\n"
            )
            self._commit_meta_count += 1

        # If we hit any already-seen commit, the rest of this branch is shared
        # history (commits are newest-first). Stop paginating.
        if hit_seen and nodes:
            logger.debug(f"Dedup exit: hit seen commit on {owner}/{repo}/{branch}, stopping pagination")
            self._stop_pagination = True
            return

    # ------------------------------------------------------------------
    # get_updated_state: per-partition cursor with head_sha + pushed_at
    # ------------------------------------------------------------------

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = (
            f"{latest_record.get('repo_owner', '')}/"
            f"{latest_record.get('repo_name', '')}/"
            f"{latest_record.get('branch_name', '')}"
        )
        if partition_key in self._partitions_with_errors:
            return current_stream_state

        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(self.cursor_field, "")
        head_sha = latest_record.get("head_sha", "")
        cursor_entry = dict(current_stream_state.get(partition_key, {}))
        if record_cursor > current_cursor:
            cursor_entry[self.cursor_field] = record_cursor
        if head_sha:
            cursor_entry["head_sha"] = head_sha
        if cursor_entry:
            current_stream_state[partition_key] = cursor_entry

            # Mirror cursor to skipped siblings (same HEAD SHA)
            for sibling_key in self._current_skipped_siblings:
                sibling_cursor = current_stream_state.get(sibling_key, {}).get(self.cursor_field, "")
                if record_cursor > sibling_cursor:
                    current_stream_state[sibling_key] = dict(cursor_entry)

        # Store repo pushed_at for freshness gate
        repo_pushed_at = latest_record.get("repo_pushed_at", "")
        if repo_pushed_at:
            owner = latest_record.get("repo_owner", "")
            repo_name = latest_record.get("repo_name", "")
            repo_state_key = f"_repo:{owner}/{repo_name}"
            current_stream_state[repo_state_key] = {"pushed_at": repo_pushed_at}

        # Apply deferred state updates (from seen-hash skipped branches in stream_slices)
        if self._deferred_state_updates:
            for key, entry in self._deferred_state_updates.items():
                if key not in current_stream_state:
                    current_stream_state[key] = entry
                else:
                    current_stream_state[key] = {**current_stream_state[key], **entry}
            self._deferred_state_updates.clear()

        return current_stream_state

    def get_commit_meta_path(self) -> str:
        """Return path to temp file with commit metadata for file_changes.

        Format: TSV with columns sha, owner, repo, committed_at, parent_count.
        Must be called after the commits stream has been fully driven by the CDK.
        """
        if not self._commit_meta_file.closed:
            self._commit_meta_file.close()
        logger.info(f"Commit metadata: {self._commit_meta_count} rows written to {self._commit_meta_path}")
        return self._commit_meta_path

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
                "sha": {"type": "string"},
                "message": {"type": ["null", "string"]},
                "committed_date": {"type": ["null", "string"]},
                "authored_date": {"type": ["null", "string"]},
                "additions": {"type": ["null", "integer"]},
                "deletions": {"type": ["null", "integer"]},
                "changed_files": {"type": ["null", "integer"]},
                "author_name": {"type": ["null", "string"]},
                "author_email": {"type": ["null", "string"]},
                "author_login": {"type": ["null", "string"]},
                "author_id": {"type": ["null", "integer"]},
                "committer_name": {"type": ["null", "string"]},
                "committer_email": {"type": ["null", "string"]},
                "committer_login": {"type": ["null", "string"]},
                "committer_id": {"type": ["null", "integer"]},
                "parent_hashes": {"type": ["null", "array"], "items": {"type": "string"}},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
                "branch_name": {"type": "string"},
                "default_branch_name": {"type": ["null", "string"]},
            },
        }

"""GitHub commits stream (GraphQL, incremental, partitioned by repo+branch)."""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_github.graphql.queries import BULK_COMMIT_QUERY
from source_github.streams.base import GitHubGraphQLStream, _make_pk
from source_github.streams.branches import BranchesStream

logger = logging.getLogger("airbyte")


class CommitsStream(GitHubGraphQLStream):
    """Fetches commits via GraphQL bulk query, partitioned by repo+branch."""

    name = "commits"
    cursor_field = "committed_date"
    use_cache = True  # commit_files stream reads from this

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

    def _query(self) -> str:
        return BULK_COMMIT_QUERY

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        if stream_slice is None:
            # Called by child stream without a slice — iterate all branch slices
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

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}

        # Collect all branches per repo, then dedup by HEAD SHA
        # Key: (owner, repo) -> list of branch records
        repo_branches: dict[tuple, list] = {}
        for record in self._parent.read_records(sync_mode=None):
            owner = record.get("_owner", "")
            repo = record.get("_repo", "")
            if owner and repo:
                repo_branches.setdefault((owner, repo), []).append(record)

        for (owner, repo), branches in repo_branches.items():
            # Two passes: first find the default branch name, then dedup
            default_branch = ""
            for record in branches:
                db = record.get("_default_branch", "")
                if db:
                    default_branch = db
                    break

            # Sort: default branch first so it wins ties
            def _sort_key(r):
                return 0 if r.get("name") == default_branch else 1

            seen_heads: dict[str, str] = {}  # head_sha -> chosen branch name
            # Track which branches were skipped and what they mapped to
            skipped_map: dict[str, str] = {}  # skipped_branch -> chosen_branch
            selected = []
            for record in sorted(branches, key=_sort_key):
                branch = record.get("name", "")
                head_sha = (record.get("commit") or {}).get("sha", "")

                if not head_sha:
                    selected.append(record)
                    continue

                if head_sha in seen_heads:
                    skipped_map[branch] = seen_heads[head_sha]
                    logger.debug(
                        f"Branch dedup: {owner}/{repo} — skipping '{branch}' "
                        f"(same HEAD {head_sha[:8]} as '{seen_heads[head_sha]}')"
                    )
                    continue

                seen_heads[head_sha] = branch
                selected.append(record)

            if skipped_map:
                logger.info(
                    f"Branch dedup: {owner}/{repo} — {len(selected)} of {len(branches)} branches "
                    f"selected, {len(skipped_map)} skipped (duplicate HEAD SHAs)"
                )

            for record in selected:
                branch = record.get("name", "")
                partition_key = f"{owner}/{repo}/{branch}"
                cursor_value = state.get(partition_key, {}).get(self.cursor_field)
                yield {
                    "owner": owner,
                    "repo": repo,
                    "branch": branch,
                    "partition_key": partition_key,
                    "cursor_value": cursor_value,
                    # Pass skipped siblings so get_updated_state can mirror cursor
                    "_skipped_siblings": [
                        f"{owner}/{repo}/{sb}" for sb, chosen in skipped_map.items()
                        if chosen == branch
                    ],
                }

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = f"{latest_record.get('_owner', '')}/{latest_record.get('_repo', '')}/{latest_record.get('_branch', '')}"
        # Don't advance cursor for partitions that had partial errors
        if partition_key in self._partitions_with_errors:
            return current_stream_state
        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(self.cursor_field, "")
        if record_cursor > current_cursor:
            cursor_entry = {self.cursor_field: record_cursor}
            current_stream_state[partition_key] = cursor_entry
            # Mirror cursor to branches that were skipped (same HEAD SHA)
            for sibling_key in self._current_skipped_siblings:
                sibling_cursor = current_stream_state.get(sibling_key, {}).get(self.cursor_field, "")
                if record_cursor > sibling_cursor:
                    current_stream_state[sibling_key] = {self.cursor_field: record_cursor}
        return current_stream_state

    def parse_response(self, response, stream_slice=None, **kwargs):
        # Track skipped siblings from current slice for cursor mirroring
        s = stream_slice or {}
        self._current_skipped_siblings = s.get("_skipped_siblings", [])

        body = response.json()
        self._update_graphql_rate_limit(body)
        self._rate_limiter.wait_if_needed("graphql")

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(f"GraphQL query failed: {body['errors']}")
            # Partial error: emit available data but freeze cursor so next run re-fetches
            logger.warning(f"GraphQL partial errors (emitting data, freezing cursor): {body['errors']}")
            s = stream_slice or {}
            partition_key = f"{s.get('owner', '')}/{s.get('repo', '')}/{s.get('branch', '')}"
            self._partitions_with_errors.add(partition_key)

        data = body.get("data", {})
        nodes = self._extract_nodes(data)
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        branch = s.get("branch", "")

        for node in nodes:
            commit_hash = node.get("oid", "")
            author = node.get("author") or {}
            author_user = author.get("user") or {}
            committer = node.get("committer") or {}
            committer_user = committer.get("user") or {}

            record = {
                "pk": _make_pk(self._tenant_id, self._source_instance_id, owner, repo, commit_hash),
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
                "_owner": owner,
                "_repo": repo,
                "_branch": branch,
            }
            yield self._add_envelope(record)

    def get_json_schema(self) -> Mapping[str, Any]:
        return {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "pk": {"type": "string"},
                "tenant_id": {"type": "string"},
                "source_instance_id": {"type": "string"},
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
                "_owner": {"type": "string"},
                "_repo": {"type": "string"},
                "_branch": {"type": "string"},
            },
        }

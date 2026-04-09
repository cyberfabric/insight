"""GitHub PR commits stream (GraphQL, per-PR sequential, incremental).

CDK-native: extends GitHubGraphQLStream. stream_slices yields one slice
per PR, CDK handles pagination (pageInfo), retry, and backoff via the
base class. Zero manual HTTP code.

Optimization: embedded commits from the parent PR query are yielded first.
If the PR has <= 100 commits (commits_complete=True), no additional API
call is needed. Otherwise, pagination continues from the embedded end_cursor.
"""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_github_v2.queries import PR_COMMITS_QUERY
from source_github_v2.streams.base import (
    GitHubAuthError,
    GitHubGraphQLStream,
    _make_unique_key,
    _now_iso,
)

logger = logging.getLogger("airbyte")


class PRCommitsStream(GitHubGraphQLStream):
    """Fetches commits linked to each PR via GraphQL with CDK-managed pagination.

    No 250-commit cap (unlike REST endpoint). Uses per-PR incremental state
    keyed by owner/repo/pr_number with synced_at = parent PR updated_at.
    """

    name = "pull_request_commits"
    cursor_field = "pull_request_updated_at"

    def __init__(self, parent, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._partitions_with_errors: set = set()

    def _query(self) -> str:
        return PR_COMMITS_QUERY

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        total = 0
        skipped = 0
        for pr in self._parent.get_child_slices():
            owner = pr.get("repo_owner", "")
            repo = pr.get("repo_name", "")
            pr_number = pr.get("number")
            pr_database_id = pr.get("database_id")
            pr_updated_at = pr.get("updated_at", "")
            pr_commit_count = pr.get("commit_count")
            if not (owner and repo and pr_number):
                continue
            total += 1
            partition_key = f"{owner}/{repo}/{pr_number}"
            child_cursor = state.get(partition_key, {}).get("synced_at", "")
            if pr_updated_at and child_cursor and pr_updated_at <= child_cursor:
                skipped += 1
                continue
            yield {
                "owner": owner,
                "repo": repo,
                "pr_number": pr_number,
                "pr_database_id": pr_database_id,
                "pr_updated_at": pr_updated_at,
                "pr_commit_count": pr_commit_count,
                "partition_key": partition_key,
                "embedded_offset": pr.get("embedded_offset", 0),
                "commits_complete": pr.get("commits_complete", False),
                "commits_end_cursor": pr.get("commits_end_cursor"),
            }
        if skipped:
            logger.info(
                f"PR commits: {total - skipped}/{total} PRs need commit sync ({skipped} skipped, unchanged)"
            )

    def _variables(self, stream_slice=None, next_page_token=None) -> dict:
        s = stream_slice or {}
        variables: dict = {
            "owner": s.get("owner", ""),
            "repo": s.get("repo", ""),
            "prNumber": s.get("pr_number"),
            "first": 100,
        }
        if next_page_token and "after" in next_page_token:
            variables["after"] = next_page_token["after"]
        elif s.get("_overflow_after"):
            variables["after"] = s["_overflow_after"]
        return variables

    def _extract_nodes(self, data: dict) -> list:
        return self._safe_get(data, "repository", "pullRequest", "commits", "nodes") or []

    def _extract_page_info(self, data: dict) -> dict:
        return self._safe_get(data, "repository", "pullRequest", "commits", "pageInfo") or {}

    def parse_response(self, response, stream_slice=None, **kwargs):
        """CDK calls this for each page. Extract commits from GraphQL nodes."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")
        pr_database_id = s.get("pr_database_id")
        pr_updated_at = s.get("pr_updated_at", "")
        pr_id = str(pr_database_id) if pr_database_id is not None else ""

        body = response.json()
        self._update_graphql_rate_limit(body, response)

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(
                    f"GraphQL errors for {owner}/{repo} PR#{pr_number} commits: {body['errors']}"
                )
            logger.warning(
                f"GraphQL partial errors (emitting data, freezing cursor): {body['errors']}"
            )
            partition_key = s.get("partition_key", f"{owner}/{repo}/{pr_number}")
            self._partitions_with_errors.add(partition_key)

        data = body.get("data", {})
        nodes = self._extract_nodes(data)

        for node in nodes:
            commit = node.get("commit") or {}
            sha = commit.get("oid", "")
            if not sha:
                continue
            yield {
                "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, pr_id, sha),
                "tenant_id": self._tenant_id,
                "source_id": self._source_id,
                "data_source": "insight_github",
                "collected_at": _now_iso(),
                "pull_request_id": pr_database_id,
                "pr_number": pr_number,
                "sha": sha,
                "committed_date": commit.get("committedDate"),
                "pull_request_updated_at": pr_updated_at,
                "repo_owner": owner,
                "repo_name": repo,
            }

    def _records_from_embedded_commits(self, commits_data, stream_slice):
        """Produce output records from embedded commit nodes (same format as parse_response)."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")
        pr_database_id = s.get("pr_database_id")
        pr_updated_at = s.get("pr_updated_at", "")
        pr_id = str(pr_database_id) if pr_database_id is not None else ""

        nodes = commits_data.get("nodes") or []
        for node in nodes:
            commit = node.get("commit") or {}
            sha = commit.get("oid", "")
            if not sha:
                continue
            yield {
                "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, pr_id, sha),
                "tenant_id": self._tenant_id,
                "source_id": self._source_id,
                "data_source": "insight_github",
                "collected_at": _now_iso(),
                "pull_request_id": pr_database_id,
                "pr_number": pr_number,
                "sha": sha,
                "committed_date": commit.get("committedDate"),
                "pull_request_updated_at": pr_updated_at,
                "repo_owner": owner,
                "repo_name": repo,
            }

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        """Yield embedded records first, then overflow-paginate if needed."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")

        try:
            # Step 1: read embedded records from disk
            commits_data = self._parent.read_embedded_data(s.get("embedded_offset", 0), "commits")
            embedded_data_available = bool(commits_data)
            embedded_count = 0
            for record in self._records_from_embedded_commits(commits_data, stream_slice):
                embedded_count += 1
                yield record

            # Step 2: if embedded data was read successfully, check completeness
            if embedded_data_available and s.get("commits_complete", False):
                logger.debug(f"PR commits {owner}/{repo} PR#{pr_number}: {embedded_count} embedded (complete)")
                return

            # Step 3: overflow or full fetch if embedded data was missing/incomplete
            if not embedded_data_available:
                logger.debug(f"PR commits {owner}/{repo} PR#{pr_number}: no embedded data, full fetch")
            else:
                logger.debug(f"PR commits {owner}/{repo} PR#{pr_number}: {embedded_count} embedded, overflow needed")
            end_cursor = s.get("commits_end_cursor") if embedded_data_available else None
            if end_cursor:
                overflow_slice = dict(s)
                overflow_slice["_overflow_after"] = end_cursor
                yield from super().read_records(
                    sync_mode=sync_mode, stream_slice=overflow_slice,
                    stream_state=stream_state, **kwargs,
                )
            else:
                yield from super().read_records(
                    sync_mode=sync_mode, stream_slice=stream_slice,
                    stream_state=stream_state, **kwargs,
                )
        except GitHubAuthError:
            raise
        except Exception as exc:
            pk = s.get("partition_key", "?")
            logger.error(f"Failed pr_commits slice {pk}: {exc}")
            raise

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        owner = latest_record.get("repo_owner", "")
        repo = latest_record.get("repo_name", "")
        pr_number = latest_record.get("pr_number")
        partition_key = f"{owner}/{repo}/{pr_number}" if (owner and repo and pr_number) else ""
        if partition_key in self._partitions_with_errors:
            return current_stream_state
        pr_updated_at = latest_record.get("pull_request_updated_at", "")
        if partition_key and pr_updated_at:
            current_stream_state[partition_key] = {"synced_at": pr_updated_at}
        return current_stream_state

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
                "pull_request_id": {"type": ["null", "integer"]},
                "pr_number": {"type": ["null", "integer"]},
                "sha": {"type": ["null", "string"]},
                "committed_date": {"type": ["null", "string"]},
                "pull_request_updated_at": {"type": ["null", "string"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

"""GitHub PR commits stream (GraphQL, sub-stream of pull requests, concurrent, incremental)."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_github.clients.auth import graphql_headers
from source_github.clients.concurrent import fetch_parallel_with_slices
from source_github.graphql.queries import PR_COMMITS_QUERY
from source_github.streams.base import GitHubRestStream, _is_fatal, _make_pk, _make_unique_key, _now_iso
from source_github.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")


class PRCommitsStream(GitHubRestStream):
    """Fetches commits linked to each PR via GraphQL with proper pagination.

    No 250-commit cap (unlike REST endpoint). Uses per-PR incremental state
    keyed by owner/repo/pr_number with synced_at = parent PR updated_at.
    """

    name = "pull_request_commits"
    cursor_field = "pr_updated_at"

    def __init__(self, parent: PullRequestsStream, max_workers: int = 5, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._max_workers = max_workers
        self._state: MutableMapping[str, Any] = {}

    def _path(self, **kwargs) -> str:
        return ""

    @property
    def state(self) -> MutableMapping[str, Any]:
        return self._state

    @state.setter
    def state(self, value: MutableMapping[str, Any]):
        self._state = value or {}

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or self._state
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
            }
        if skipped:
            logger.info(f"PR commits: {total - skipped}/{total} PRs need commit sync ({skipped} skipped, unchanged)")

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        return self._state

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_state:
            self._state = stream_state

        if stream_slice is not None:
            records = self._fetch_pr_commits(stream_slice)
            yield from records
            self._advance_state(stream_slice)
        else:
            for result in fetch_parallel_with_slices(
                self._fetch_pr_commits, self.stream_slices(stream_state=stream_state), self._max_workers
            ):
                if result.error is not None:
                    if _is_fatal(result.error):
                        raise result.error
                    logger.warning(f"Skipping PR commits slice {result.slice.get('partition_key', '?')}: {result.error}")
                    continue
                yield from result.records
                self._advance_state(result.slice)

    def _advance_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        pr_updated_at = stream_slice.get("pr_updated_at", "")
        if partition_key and pr_updated_at:
            self._state[partition_key] = {"synced_at": pr_updated_at}

    def _graphql_post(self, variables: dict) -> dict:
        """Make a GraphQL POST request. Thread-safe. Raises on transient errors."""
        self._rate_limiter.wait_if_needed("graphql")
        resp = req.post(
            "https://api.github.com/graphql",
            json={"query": PR_COMMITS_QUERY, "variables": variables},
            headers=graphql_headers(self._token),
            timeout=30,
        )
        # Always update rate limit from headers before any error handling
        hdr_remaining = resp.headers.get("x-ratelimit-remaining")
        hdr_reset = resp.headers.get("x-ratelimit-reset")
        if hdr_remaining is not None and hdr_reset is not None:
            from datetime import datetime, timezone
            reset_dt = datetime.fromtimestamp(float(hdr_reset), tz=timezone.utc)
            self._rate_limiter.update_graphql(int(hdr_remaining), reset_dt.isoformat())
        if resp.status_code in (502, 503):
            self._rate_limiter.on_secondary_limit()
            raise RuntimeError(f"GitHub secondary rate limit ({resp.status_code})")
        if resp.status_code == 429 or resp.status_code >= 400:
            raise RuntimeError(f"GitHub GraphQL error {resp.status_code}: {resp.text[:500]}")
        body = resp.json()
        # Also update from response body (more precise)
        rate_limit = body.get("data", {}).get("rateLimit", {})
        remaining = rate_limit.get("remaining")
        reset_at = rate_limit.get("resetAt")
        if remaining is not None and reset_at:
            self._rate_limiter.update_graphql(remaining, reset_at)
        return body

    def _fetch_pr_commits(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch all commits for one PR via GraphQL with pagination. Thread-safe."""
        owner = stream_slice.get("owner", "")
        repo = stream_slice.get("repo", "")
        pr_number = stream_slice.get("pr_number")
        pr_database_id = stream_slice.get("pr_database_id")
        pr_updated_at = stream_slice.get("pr_updated_at", "")
        pr_commit_count = stream_slice.get("pr_commit_count")
        pr_id = str(pr_database_id) if pr_database_id is not None else ""
        records = []

        after = None
        while True:
            variables = {
                "owner": owner,
                "repo": repo,
                "prNumber": pr_number,
                "first": 100,
            }
            if after:
                variables["after"] = after

            body = self._graphql_post(variables)

            if "errors" in body:
                raise RuntimeError(
                    f"GraphQL errors for {owner}/{repo} PR#{pr_number} commits: {body['errors']}"
                )

            pr_data = (body.get("data", {}).get("repository", {}).get("pullRequest") or {})
            commits_data = pr_data.get("commits") or {}
            nodes = commits_data.get("nodes") or []
            page_info = commits_data.get("pageInfo") or {}

            for node in nodes:
                commit = node.get("commit") or {}
                sha = commit.get("oid", "")
                if not sha:
                    continue
                records.append({
                    "pk": _make_pk(self._tenant_id, self._source_id, owner, repo, pr_id, sha),
                    "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, pr_id, sha),
                    "tenant_id": self._tenant_id,
                    "source_id": self._source_id,
                    "data_source": "insight_github",
                    "collected_at": _now_iso(),
                    "pr_database_id": pr_database_id,
                    "pr_number": pr_number,
                    "commit_hash": sha,
                    "commit_committed_date": commit.get("committedDate"),
                    "commit_order": len(records),
                    "pr_updated_at": pr_updated_at,
                    "partition_key": stream_slice.get("partition_key"),
                    "repo_owner": owner,
                    "repo_name": repo,
                })

            if page_info.get("hasNextPage"):
                after = page_info["endCursor"]
            else:
                break

        # Sanity check against parent commit_count
        if pr_commit_count is not None and len(records) != pr_commit_count:
            if abs(len(records) - pr_commit_count) > 1:  # Allow off-by-one
                logger.warning(
                    f"PR {owner}/{repo}#{pr_number}: fetched {len(records)} commits "
                    f"but parent reported commit_count={pr_commit_count}"
                )

        return records

    def next_page_token(self, response, **kwargs):
        return None

    def parse_response(self, response, stream_slice=None, **kwargs):
        return []

    def get_json_schema(self) -> Mapping[str, Any]:
        return {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "pk": {"type": "string"},
                "tenant_id": {"type": "string"},
                "source_id": {"type": "string"},
                "unique_key": {"type": "string"},
                "data_source": {"type": "string"},
                "collected_at": {"type": "string"},
                "pr_database_id": {"type": ["null", "integer"]},
                "pr_number": {"type": ["null", "integer"]},
                "commit_hash": {"type": ["null", "string"]},
                "commit_committed_date": {"type": ["null", "string"]},
                "commit_order": {"type": ["null", "integer"]},
                "pr_updated_at": {"type": ["null", "string"]},
                "partition_key": {"type": ["null", "string"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

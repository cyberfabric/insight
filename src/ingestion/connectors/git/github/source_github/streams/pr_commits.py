"""GitHub PR commits stream (REST, sub-stream of pull requests, concurrent, incremental)."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_github.clients.auth import rest_headers
from source_github.clients.concurrent import fetch_parallel_with_slices
from source_github.streams.base import GitHubRestStream, _make_pk, _now_iso, check_rest_response
from source_github.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")


class PRCommitsStream(GitHubRestStream):
    """Fetches commits linked to each PR via REST.

    Incremental: only fetches for PRs whose updated_at is newer
    than the stored child cursor for that PR.
    """

    name = "pull_request_commits"
    cursor_field = "pr_updated_at"

    def __init__(self, parent: PullRequestsStream, max_workers: int = 5, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._max_workers = max_workers
        self._state: MutableMapping[str, Any] = {}

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        return f"repos/{s['owner']}/{s['repo']}/pulls/{s['pr_number']}/commits"

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
        for pr in self._parent.read_records(sync_mode=None):
            owner = pr.get("_owner", "")
            repo = pr.get("_repo", "")
            pr_number = pr.get("number")
            pr_database_id = pr.get("database_id")
            pr_updated_at = pr.get("updated_at", "")
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
            slices = list(self.stream_slices(stream_state=stream_state))
            if not slices:
                return
            for result in fetch_parallel_with_slices(self._fetch_pr_commits, slices, self._max_workers):
                if result.error is not None:
                    raise result.error
                yield from result.records
                self._advance_state(result.slice)

    def _advance_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        pr_updated_at = stream_slice.get("pr_updated_at", "")
        if partition_key and pr_updated_at:
            self._state[partition_key] = {"synced_at": pr_updated_at}

    def _fetch_pr_commits(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch commits for one PR with pagination. Thread-safe."""
        owner = stream_slice.get("owner", "")
        repo = stream_slice.get("repo", "")
        pr_number = stream_slice.get("pr_number")
        pr_database_id = stream_slice.get("pr_database_id")
        pr_id = str(pr_database_id) if pr_database_id is not None else ""
        records = []

        url = f"https://api.github.com/repos/{owner}/{repo}/pulls/{pr_number}/commits"
        params = {"per_page": "100"}

        while url:
            resp = req.get(url, headers=rest_headers(self._token), params=params, timeout=30)
            params = {}

            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{owner}/{repo} PR#{pr_number} commits"):
                break

            commits = resp.json()
            if not isinstance(commits, list):
                commits = [commits]

            for commit in commits:
                sha = commit.get("sha", "")
                records.append({
                    "pk": _make_pk(self._tenant_id, self._source_instance_id, owner, repo, pr_id, sha),
                    "tenant_id": self._tenant_id,
                    "source_instance_id": self._source_instance_id,
                    "data_source": "insight_github",
                    "collected_at": _now_iso(),
                    "pr_database_id": pr_database_id,
                    "pr_number": pr_number,
                    "commit_hash": sha,
                    "commit_order": len(records),
                    "pr_updated_at": stream_slice.get("pr_updated_at"),
                    "_partition_key": stream_slice.get("partition_key"),
                    "_owner": owner,
                    "_repo": repo,
                })

            url = resp.links.get("next", {}).get("url")

        # GitHub caps this endpoint at 250 commits total
        if len(records) >= 250:
            logger.warning(
                f"PR {owner}/{repo}#{pr_number} returned {len(records)} commits — "
                f"GitHub caps this endpoint at 250, linkage may be incomplete"
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
                "source_instance_id": {"type": "string"},
                "data_source": {"type": "string"},
                "collected_at": {"type": "string"},
                "pr_database_id": {"type": ["null", "integer"]},
                "pr_number": {"type": ["null", "integer"]},
                "commit_hash": {"type": ["null", "string"]},
                "commit_order": {"type": ["null", "integer"]},
                "pr_updated_at": {"type": ["null", "string"]},
                "_owner": {"type": "string"},
                "_repo": {"type": "string"},
            },
        }

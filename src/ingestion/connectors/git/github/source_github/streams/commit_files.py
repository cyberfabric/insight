"""GitHub commit files stream (REST, sub-stream of commits, concurrent, incremental)."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_github.clients.auth import rest_headers
from source_github.clients.concurrent import fetch_parallel_with_slices
from source_github.streams.base import GitHubRestStream, _make_pk, _now_iso, check_rest_response
from source_github.streams.commits import CommitsStream

logger = logging.getLogger("airbyte")


class CommitFilesStream(GitHubRestStream):
    """Fetches per-file line changes for each commit via REST.

    Incremental: tracks which commit SHAs have been processed and skips
    them on subsequent runs. Handles GitHub's file pagination for large
    commits (300+ files).
    """

    name = "commit_files"
    cursor_field = "committed_date"

    def __init__(self, parent: CommitsStream, max_workers: int = 5, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._max_workers = max_workers
        self._state: MutableMapping[str, Any] = {}

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        return f"repos/{s.get('owner', '')}/{s.get('repo', '')}/commits/{s.get('sha', '')}"

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
        for record in self._parent.read_records(sync_mode=None):
            owner = record.get("_owner", "")
            repo = record.get("_repo", "")
            sha = record.get("oid", "")
            if not sha:
                continue
            total += 1
            partition_key = f"{owner}/{repo}/{sha}"
            if state.get(partition_key, {}).get("seen"):
                skipped += 1
                continue
            yield {
                "owner": owner,
                "repo": repo,
                "sha": sha,
                "committed_date": record.get("committed_date"),
                "partition_key": partition_key,
            }
        if skipped:
            logger.info(f"Commit files: {total - skipped}/{total} commits need file sync ({skipped} skipped, already seen)")

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
            records = self._fetch_commit_files(stream_slice)
            yield from records
            self._advance_state(stream_slice)
        else:
            for result in fetch_parallel_with_slices(
                self._fetch_commit_files, self.stream_slices(stream_state=stream_state), self._max_workers
            ):
                if result.error is not None:
                    raise result.error
                yield from result.records
                self._advance_state(result.slice)

    def _advance_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        if partition_key:
            self._state[partition_key] = {"seen": True}

    def _fetch_commit_files(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch file stats for one commit with pagination. Thread-safe."""
        owner = stream_slice.get("owner", "")
        repo = stream_slice.get("repo", "")
        sha = stream_slice.get("sha", "")
        records = []

        url = f"https://api.github.com/repos/{owner}/{repo}/commits/{sha}"
        params = {"per_page": "100"}

        while url:
            resp = req.get(url, headers=rest_headers(self._token), params=params, timeout=30)
            params = {}

            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{owner}/{repo}/{sha} files"):
                return records

            data = resp.json()
            files = data.get("files", [])

            for f in files:
                filename = f.get("filename", "")
                records.append({
                    "pk": _make_pk(self._tenant_id, self._source_instance_id, owner, repo, sha, filename),
                    "tenant_id": self._tenant_id,
                    "source_instance_id": self._source_instance_id,
                    "data_source": "insight_github",
                    "collected_at": _now_iso(),
                    "commit_hash": sha,
                    "filename": filename,
                    "status": f.get("status"),
                    "additions": f.get("additions"),
                    "deletions": f.get("deletions"),
                    "changes": f.get("changes"),
                    "previous_filename": f.get("previous_filename"),
                    "patch": f.get("patch"),  # None for binary files
                    "blob_url": f.get("blob_url"),
                    "raw_url": f.get("raw_url"),
                    "contents_url": f.get("contents_url"),
                    "sha": f.get("sha"),  # blob SHA
                    "committed_date": stream_slice.get("committed_date"),
                    "_partition_key": stream_slice.get("partition_key"),
                    "_owner": owner,
                    "_repo": repo,
                })

            url = resp.links.get("next", {}).get("url")

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
                "commit_hash": {"type": "string"},
                "filename": {"type": ["null", "string"]},
                "status": {"type": ["null", "string"]},
                "additions": {"type": ["null", "integer"]},
                "deletions": {"type": ["null", "integer"]},
                "changes": {"type": ["null", "integer"]},
                "previous_filename": {"type": ["null", "string"]},
                "patch": {"type": ["null", "string"]},
                "blob_url": {"type": ["null", "string"]},
                "raw_url": {"type": ["null", "string"]},
                "contents_url": {"type": ["null", "string"]},
                "sha": {"type": ["null", "string"]},
                "committed_date": {"type": ["null", "string"]},
                "_owner": {"type": "string"},
                "_repo": {"type": "string"},
            },
        }

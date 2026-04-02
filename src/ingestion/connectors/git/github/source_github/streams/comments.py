"""GitHub PR comments stream (REST, paginated per PR, concurrent, incremental)."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_github.clients.auth import rest_headers
from source_github.clients.concurrent import fetch_parallel_with_slices
from source_github.streams.base import GitHubRestStream, _make_pk, _now_iso, check_rest_response
from source_github.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")


class CommentsStream(GitHubRestStream):
    """Fetches general + inline review comments for each PR via REST.

    Incremental: only fetches comments for PRs whose updated_at is newer
    than the stored child cursor for that PR.
    """

    name = "pull_request_comments"
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
            logger.info(f"Comments: {total - skipped}/{total} PRs need comment sync ({skipped} skipped, unchanged)")

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
            records = self._fetch_all_comments(stream_slice)
            yield from records
            self._advance_state(stream_slice)
        else:
            slices = list(self.stream_slices(stream_state=stream_state))
            if not slices:
                return
            for result in fetch_parallel_with_slices(self._fetch_all_comments, slices, self._max_workers):
                if result.error is not None:
                    raise result.error
                yield from result.records
                self._advance_state(result.slice)

    def _advance_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        pr_updated_at = stream_slice.get("pr_updated_at", "")
        if partition_key and pr_updated_at:
            self._state[partition_key] = {"synced_at": pr_updated_at}

    def _fetch_all_comments(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch both general and inline comments for one PR. Thread-safe."""
        records = []
        records.extend(self._fetch_paginated(stream_slice, comment_type="general"))
        records.extend(self._fetch_paginated(stream_slice, comment_type="inline"))
        return records

    def _fetch_paginated(self, stream_slice: dict, comment_type: str) -> List[Mapping[str, Any]]:
        owner = stream_slice.get("owner", "")
        repo = stream_slice.get("repo", "")
        pr_number = stream_slice.get("pr_number")
        pr_database_id = stream_slice.get("pr_database_id")
        pr_id = str(pr_database_id) if pr_database_id is not None else ""
        records = []

        if comment_type == "general":
            url = f"https://api.github.com/repos/{owner}/{repo}/issues/{pr_number}/comments"
        else:
            url = f"https://api.github.com/repos/{owner}/{repo}/pulls/{pr_number}/comments"

        is_inline = comment_type == "inline"
        pk_prefix = "r" if is_inline else "c"
        params = {"per_page": "100"}

        while url:
            resp = req.get(url, headers=rest_headers(self._token), params=params, timeout=30)
            params = {}

            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{owner}/{repo} PR#{pr_number} {comment_type} comments"):
                break

            comments = resp.json()
            if not isinstance(comments, list):
                comments = [comments]

            for comment in comments:
                comment_id = str(comment.get("id", ""))
                user = comment.get("user") or {}
                record = {
                    "pk": _make_pk(self._tenant_id, self._source_instance_id, owner, repo, pr_id, pk_prefix, comment_id),
                    "tenant_id": self._tenant_id,
                    "source_instance_id": self._source_instance_id,
                    "data_source": "insight_github",
                    "collected_at": _now_iso(),
                    "database_id": comment.get("id"),
                    "pr_number": pr_number,
                    "pr_database_id": pr_database_id,
                    "body": comment.get("body"),
                    "path": comment.get("path") if is_inline else None,
                    "line": comment.get("line") if is_inline else None,
                    "is_inline": is_inline,
                    "created_at": comment.get("created_at"),
                    "updated_at": comment.get("updated_at"),
                    "author_login": user.get("login"),
                    "author_database_id": user.get("id"),
                    "author_email": None,
                    "author_association": comment.get("author_association"),
                    "pr_updated_at": stream_slice.get("pr_updated_at"),
                    "_partition_key": stream_slice.get("partition_key"),
                    "_owner": owner,
                    "_repo": repo,
                }
                # Inline review comments have additional diff context fields
                if is_inline:
                    record["diff_hunk"] = comment.get("diff_hunk")
                    record["commit_id"] = comment.get("commit_id")
                    record["original_commit_id"] = comment.get("original_commit_id")
                    record["original_line"] = comment.get("original_line")
                    record["original_position"] = comment.get("original_position")
                    record["start_line"] = comment.get("start_line")
                    record["start_side"] = comment.get("start_side")
                    record["side"] = comment.get("side")
                    record["in_reply_to_id"] = comment.get("in_reply_to_id")
                records.append(record)

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
                "database_id": {"type": ["null", "integer"]},
                "pr_number": {"type": ["null", "integer"]},
                "pr_database_id": {"type": ["null", "integer"]},
                "body": {"type": ["null", "string"]},
                "path": {"type": ["null", "string"]},
                "line": {"type": ["null", "integer"]},
                "is_inline": {"type": ["null", "boolean"]},
                "created_at": {"type": ["null", "string"]},
                "updated_at": {"type": ["null", "string"]},
                "author_login": {"type": ["null", "string"]},
                "author_database_id": {"type": ["null", "integer"]},
                "author_email": {"type": ["null", "string"]},
                "author_association": {"type": ["null", "string"]},
                "diff_hunk": {"type": ["null", "string"]},
                "commit_id": {"type": ["null", "string"]},
                "original_commit_id": {"type": ["null", "string"]},
                "original_line": {"type": ["null", "integer"]},
                "original_position": {"type": ["null", "integer"]},
                "start_line": {"type": ["null", "integer"]},
                "start_side": {"type": ["null", "string"]},
                "side": {"type": ["null", "string"]},
                "in_reply_to_id": {"type": ["null", "integer"]},
                "pr_updated_at": {"type": ["null", "string"]},
                "_owner": {"type": "string"},
                "_repo": {"type": "string"},
            },
        }

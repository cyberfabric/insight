"""Bitbucket Cloud PR comments stream (REST, per-PR fanout, concurrent, incremental)."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_bitbucket_cloud.clients.auth import rest_headers
from source_bitbucket_cloud.clients.concurrent import fetch_parallel_with_slices, retry_request
from source_bitbucket_cloud.streams.base import BitbucketCloudRestStream, _is_fatal, _make_pk, _now_iso, check_rest_response
from source_bitbucket_cloud.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")

API_BASE = "https://api.bitbucket.org/2.0"


class PullRequestCommentsStream(BitbucketCloudRestStream):
    """Fetches comments for each PR via REST with pagination.

    API: GET /repositories/{workspace}/{repo_slug}/pullrequests/{id}/comments

    Incremental: only fetches comments for PRs whose updated_on is newer
    than the stored child cursor for that PR.
    """

    name = "pull_request_comments"
    cursor_field = "pr_updated_on"

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

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        return self._state

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or self._state
        total = 0
        skipped = 0
        for pr in self._parent.get_child_slices():
            workspace = pr.get("workspace", "")
            repo_slug = pr.get("repo_slug", "")
            pr_id = pr.get("pr_id")
            pr_updated_on = pr.get("updated_on", "")
            if not (workspace and repo_slug and pr_id is not None):
                continue
            total += 1
            partition_key = f"{workspace}/{repo_slug}/{pr_id}"
            child_cursor = state.get(partition_key, {}).get("synced_at", "")
            if pr_updated_on and child_cursor and pr_updated_on <= child_cursor:
                skipped += 1
                continue
            yield {
                "workspace": workspace,
                "repo_slug": repo_slug,
                "pr_id": pr_id,
                "pr_updated_on": pr_updated_on,
                "partition_key": partition_key,
            }
        if skipped:
            logger.info(f"Comments: {total - skipped}/{total} PRs need comment sync ({skipped} skipped, unchanged)")

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_state:
            self._state = stream_state

        if stream_slice is not None:
            records = self._fetch_comments(stream_slice)
            yield from records
            self._advance_state(stream_slice)
        else:
            for result in fetch_parallel_with_slices(
                self._fetch_comments, self.stream_slices(stream_state=stream_state), self._max_workers
            ):
                if result.error is not None:
                    if _is_fatal(result.error):
                        raise result.error
                    logger.warning(f"Skipping comment slice {result.slice.get('partition_key', '?')}: {result.error}")
                    continue
                yield from result.records
                self._advance_state(result.slice)

    def _advance_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        pr_updated_on = stream_slice.get("pr_updated_on", "")
        if partition_key and pr_updated_on:
            self._state[partition_key] = {"synced_at": pr_updated_on}

    def _do_rest_get(self, url: str, params: Optional[dict] = None) -> req.Response:
        """REST GET with page-level retry. Thread-safe."""
        def _call():
            self._rate_limiter.wait_if_needed("rest")
            resp = req.get(url, headers=rest_headers(self._username, self._token), params=params, timeout=30)
            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            if resp.status_code in (502, 503):
                self._rate_limiter.on_secondary_limit()
                raise RuntimeError(f"Bitbucket Cloud secondary rate limit ({resp.status_code}) for {url}")
            if resp.status_code == 429 or resp.status_code >= 500:
                raise RuntimeError(f"Bitbucket Cloud API error {resp.status_code} for {url}")
            return resp
        return retry_request(_call, context=url)

    def _fetch_comments(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch all comments for one PR with pagination. Thread-safe."""
        workspace = stream_slice.get("workspace", "")
        repo_slug = stream_slice.get("repo_slug", "")
        pr_id = stream_slice.get("pr_id")
        pr_updated_on = stream_slice.get("pr_updated_on", "")
        records: List[Mapping[str, Any]] = []

        url: Optional[str] = f"{API_BASE}/repositories/{workspace}/{repo_slug}/pullrequests/{pr_id}/comments"
        params: Optional[dict] = {"pagelen": "100"}

        while url:
            resp = self._do_rest_get(url, params)
            params = None  # Only on first request; subsequent pages use full next URL

            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{workspace}/{repo_slug} PR#{pr_id} comments"):
                break

            body = resp.json()
            comments = body.get("values", [])

            for comment in comments:
                comment_id = comment.get("id")
                if comment_id is None:
                    continue

                user = comment.get("user") or {}
                content = comment.get("content") or {}
                inline = comment.get("inline")
                is_inline = inline is not None

                record: dict[str, Any] = {
                    "pk": _make_pk(
                        self._tenant_id, self._source_instance_id,
                        workspace, repo_slug, str(pr_id), str(comment_id),
                    ),
                    "tenant_id": self._tenant_id,
                    "source_instance_id": self._source_instance_id,
                    "data_source": "insight_bitbucket_cloud",
                    "collected_at": _now_iso(),
                    "comment_id": comment_id,
                    "pr_id": pr_id,
                    "body": content.get("raw"),
                    "user_display_name": user.get("display_name"),
                    "user_uuid": user.get("uuid"),
                    "user_nickname": user.get("nickname"),
                    "created_on": comment.get("created_on"),
                    "updated_on": comment.get("updated_on"),
                    "is_inline": is_inline,
                    "inline_from": None,
                    "inline_to": None,
                    "inline_path": None,
                    "pr_updated_on": pr_updated_on,
                    "partition_key": stream_slice.get("partition_key"),
                    "workspace": workspace,
                    "repo_slug": repo_slug,
                }

                if is_inline and isinstance(inline, dict):
                    record["inline_from"] = inline.get("from")
                    record["inline_to"] = inline.get("to")
                    record["inline_path"] = inline.get("path")

                records.append(record)

            url = body.get("next")

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
                "comment_id": {"type": ["null", "integer"]},
                "pr_id": {"type": ["null", "integer"]},
                "body": {"type": ["null", "string"]},
                "user_display_name": {"type": ["null", "string"]},
                "user_uuid": {"type": ["null", "string"]},
                "user_nickname": {"type": ["null", "string"]},
                "created_on": {"type": ["null", "string"]},
                "updated_on": {"type": ["null", "string"]},
                "is_inline": {"type": ["null", "boolean"]},
                "inline_from": {"type": ["null", "integer"]},
                "inline_to": {"type": ["null", "integer"]},
                "inline_path": {"type": ["null", "string"]},
                "pr_updated_on": {"type": ["null", "string"]},
                "partition_key": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }

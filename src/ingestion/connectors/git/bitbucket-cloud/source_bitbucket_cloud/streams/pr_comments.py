"""Bitbucket Cloud PR comments stream (REST, per-PR, incremental).

Fetches both general discussion comments AND inline code comments from
a single endpoint. Inline comments are distinguished by the `inline` field.
"""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_bitbucket_cloud.streams.base import (
    BitbucketAuthError,
    BitbucketCloudRestStream,
    _make_unique_key,
    _now_iso,
)

logger = logging.getLogger("airbyte")


class PRCommentsStream(BitbucketCloudRestStream):
    """Fetches comments for each PR via REST API.

    Uses per-PR incremental state keyed by workspace/repo_slug/pr_id
    with synced_at = parent PR updated_on.
    """

    name = "pull_request_comments"
    cursor_field = "pull_request_updated_on"

    def __init__(self, parent, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._partitions_with_errors: set = set()

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        workspace = s.get("workspace", "")
        slug = s.get("repo_slug", "")
        pr_id = s.get("pr_id", "")
        return f"repositories/{workspace}/{slug}/pullrequests/{pr_id}/comments"

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        total = 0
        skipped = 0
        skipped_no_comments = 0
        for pr in self._parent.get_child_slices():
            workspace = pr.get("workspace", "")
            slug = pr.get("repo_slug", "")
            pr_id = pr.get("pr_id")
            pr_updated_on = pr.get("updated_on", "")
            comment_count = pr.get("comment_count")
            if not (workspace and slug and pr_id):
                continue
            total += 1
            if not comment_count:
                skipped_no_comments += 1
                continue
            partition_key = f"{workspace}/{slug}/{pr_id}"
            child_cursor = state.get(partition_key, {}).get("synced_at", "")
            if pr_updated_on and child_cursor and pr_updated_on <= child_cursor:
                skipped += 1
                continue
            yield {
                "workspace": workspace,
                "repo_slug": slug,
                "pr_id": pr_id,
                "pr_updated_on": pr_updated_on,
                "partition_key": partition_key,
            }
        fetched = total - skipped - skipped_no_comments
        if skipped or skipped_no_comments:
            logger.info(
                f"PR comments: {fetched}/{total} PRs need comment sync "
                f"({skipped} unchanged, {skipped_no_comments} zero comments)"
            )

    def parse_response(self, response, stream_slice=None, **kwargs):
        self._check_near_limit(response)

        s = stream_slice or {}
        workspace = s.get("workspace", "")
        slug = s.get("repo_slug", "")
        pr_id = s.get("pr_id")

        if response.status_code == 404:
            logger.warning(f"Skipping comments for {workspace}/{slug} PR#{pr_id} (404)")
            return

        data = response.json()
        values = data.get("values", [])

        for comment in values:
            comment_id = comment.get("id")
            if comment_id is None:
                continue

            user = comment.get("user") or {}
            content = comment.get("content") or {}
            inline = comment.get("inline")
            parent_comment = comment.get("parent")

            record = {
                "unique_key": _make_unique_key(
                    self._tenant_id, self._source_id,
                    workspace, slug, str(pr_id), str(comment_id),
                ),
                "tenant_id": self._tenant_id,
                "source_id": self._source_id,
                "data_source": "insight_bitbucket_cloud",
                "collected_at": _now_iso(),
                "comment_id": comment_id,
                "pr_id": pr_id,
                "body": content.get("raw"),
                "body_html": content.get("html"),
                "created_on": comment.get("created_on"),
                "updated_on": comment.get("updated_on"),
                "author_display_name": user.get("display_name"),
                "author_uuid": user.get("uuid"),
                "author_nickname": user.get("nickname"),
                "is_inline": inline is not None,
                "inline_path": (inline or {}).get("path"),
                "inline_from": (inline or {}).get("from"),
                "inline_to": (inline or {}).get("to"),
                "parent_comment_id": parent_comment.get("id") if parent_comment else None,
                "is_deleted": comment.get("deleted", False),
                "pull_request_updated_on": s.get("pr_updated_on"),
                "workspace": workspace,
                "repo_slug": slug,
            }
            yield record

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        s = stream_slice or {}
        if not (s.get("workspace") and s.get("repo_slug") and s.get("pr_id")):
            return
        try:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice,
                stream_state=stream_state, **kwargs,
            )
        except BitbucketAuthError:
            raise
        except Exception as exc:
            pk = s.get("partition_key", "?")
            self._partitions_with_errors.add(pk)
            logger.error(f"Failed pr_comments slice {pk}, cursor frozen: {exc}")

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        workspace = latest_record.get("workspace", "")
        slug = latest_record.get("repo_slug", "")
        pr_id = latest_record.get("pr_id")
        partition_key = f"{workspace}/{slug}/{pr_id}" if (workspace and slug and pr_id) else ""
        if partition_key in self._partitions_with_errors:
            return current_stream_state
        pr_updated_on = latest_record.get("pull_request_updated_on", "")
        if partition_key and pr_updated_on:
            current_stream_state[partition_key] = {"synced_at": pr_updated_on}
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
                "comment_id": {"type": ["null", "integer"]},
                "pr_id": {"type": ["null", "integer"]},
                "body": {"type": ["null", "string"]},
                "body_html": {"type": ["null", "string"]},
                "created_on": {"type": ["null", "string"]},
                "updated_on": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "author_nickname": {"type": ["null", "string"]},
                "is_inline": {"type": ["null", "boolean"]},
                "inline_path": {"type": ["null", "string"]},
                "inline_from": {"type": ["null", "integer"]},
                "inline_to": {"type": ["null", "integer"]},
                "parent_comment_id": {"type": ["null", "integer"]},
                "is_deleted": {"type": ["null", "boolean"]},
                "pull_request_updated_on": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }

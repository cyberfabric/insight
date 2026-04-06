"""Bitbucket Cloud PR reviews stream -- extracted from PR participants (zero API calls)."""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_bitbucket_cloud.streams.base import BitbucketCloudRestStream, _make_pk, _now_iso
from source_bitbucket_cloud.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")


class PullRequestReviewsStream(BitbucketCloudRestStream):
    """Extracts review data from PR participants cached by the parent stream.

    Key difference from GitHub: Bitbucket Cloud has no separate reviews endpoint.
    Review data is embedded in the ``participants[]`` array of each PR response.

    Filter: only participants with ``role == "REVIEWER"``.
    Mapping: ``approved: true`` -> state ``APPROVED``, ``approved: false`` -> state ``UNAPPROVED``.

    Zero additional API calls -- all data comes from the cached PR response.
    """

    name = "pull_request_reviews"
    cursor_field = "pr_updated_on"

    def __init__(self, parent: PullRequestsStream, max_workers: int = 5, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._max_workers = max_workers  # unused but kept for interface consistency
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
            participants = pr.get("participants", [])
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
                "participants": participants,
                "partition_key": partition_key,
            }
        if skipped:
            logger.info(f"Reviews: {total - skipped}/{total} PRs need review sync ({skipped} skipped, unchanged)")

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_state:
            self._state = stream_state

        if stream_slice is not None:
            yield from self._extract_reviews(stream_slice)
            self._advance_state(stream_slice)
        else:
            for pr_slice in self.stream_slices(stream_state=stream_state):
                yield from self._extract_reviews(pr_slice)
                self._advance_state(pr_slice)

    def _advance_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        pr_updated_on = stream_slice.get("pr_updated_on", "")
        if partition_key and pr_updated_on:
            self._state[partition_key] = {"synced_at": pr_updated_on}

    def _extract_reviews(self, stream_slice: Mapping[str, Any]) -> Iterable[Mapping[str, Any]]:
        """Extract reviewer records from PR participants. No API calls."""
        workspace = stream_slice.get("workspace", "")
        repo_slug = stream_slice.get("repo_slug", "")
        pr_id = stream_slice.get("pr_id")
        pr_updated_on = stream_slice.get("pr_updated_on", "")
        participants = stream_slice.get("participants", [])

        for participant in participants:
            role = participant.get("role", "")
            if role != "REVIEWER":
                continue

            # Participants are flattened by get_child_slices():
            # {display_name, uuid, nickname, role, approved, state}
            user_uuid = participant.get("uuid", "")
            approved = participant.get("approved", False)
            review_state = "APPROVED" if approved else "UNAPPROVED"

            yield {
                "pk": _make_pk(self._tenant_id, self._source_instance_id, workspace, repo_slug, str(pr_id), user_uuid),
                "tenant_id": self._tenant_id,
                "source_instance_id": self._source_instance_id,
                "data_source": "insight_bitbucket_cloud",
                "collected_at": _now_iso(),
                "pr_id": pr_id,
                "state": review_state,
                "approved": approved,
                "role": role,
                "user_display_name": participant.get("display_name"),
                "user_uuid": user_uuid,
                "user_nickname": participant.get("nickname"),
                "pr_updated_on": pr_updated_on,
                "partition_key": stream_slice.get("partition_key"),
                "workspace": workspace,
                "repo_slug": repo_slug,
            }

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
                "pr_id": {"type": ["null", "integer"]},
                "state": {"type": ["null", "string"]},
                "approved": {"type": ["null", "boolean"]},
                "role": {"type": ["null", "string"]},
                "user_display_name": {"type": ["null", "string"]},
                "user_uuid": {"type": ["null", "string"]},
                "user_nickname": {"type": ["null", "string"]},
                "pr_updated_on": {"type": ["null", "string"]},
                "partition_key": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }

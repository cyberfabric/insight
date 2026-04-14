"""Bitbucket Cloud pull requests stream (REST, incremental, child of repos)."""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_bitbucket_cloud.streams.base import (
    BitbucketAuthError,
    BitbucketCloudRestStream,
    _make_unique_key,
)
from source_bitbucket_cloud.streams.repositories import RepositoriesStream

logger = logging.getLogger("airbyte")


class PullRequestsStream(BitbucketCloudRestStream):
    """Fetches PRs via REST API, incremental by updated_on.

    Comments and PR commits are fetched by separate child streams
    that consume get_child_slices() for slice construction.
    """

    name = "pull_requests"
    cursor_field = "updated_on"

    def __init__(
        self,
        parent: RepositoriesStream,
        start_date: Optional[str] = None,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._parent = parent
        self._start_date = start_date
        self._partitions_with_errors: set = set()
        self._child_slice_cache: dict[tuple, dict] = {}
        self._current_cursor_value: Optional[str] = None

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        workspace = s.get("workspace", "")
        slug = s.get("slug", "")
        if not workspace or not slug:
            raise ValueError(
                f"PullRequestsStream._path() called with incomplete slice: "
                f"workspace={workspace}, slug={slug}"
            )
        return f"repositories/{workspace}/{slug}/pullrequests"

    def request_params(self, **kwargs) -> dict:
        return {
            "pagelen": "50",
            "state": ["OPEN", "MERGED", "DECLINED", "SUPERSEDED"],
            "sort": "-updated_on",
        }

    # ------------------------------------------------------------------
    # read_records: delegate to slices when called without a slice
    # ------------------------------------------------------------------

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        if stream_slice is None:
            for repo_slice in self.stream_slices(stream_state=stream_state):
                self._current_cursor_value = None  # reset between slices
                try:
                    yield from super().read_records(
                        sync_mode=sync_mode, stream_slice=repo_slice,
                        stream_state=stream_state, **kwargs,
                    )
                except BitbucketAuthError:
                    raise
                except Exception as exc:
                    pk = repo_slice.get("partition_key", "?")
                    self._partitions_with_errors.add(pk)
                    logger.error(f"Failed pull_requests slice {pk}, cursor frozen: {exc}")
        else:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice,
                stream_state=stream_state, **kwargs,
            )

    # ------------------------------------------------------------------
    # stream_slices
    # ------------------------------------------------------------------

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        for record in self._parent.get_child_records():
            workspace = record.get("workspace", "")
            slug = record.get("slug", "")
            if not (workspace and slug):
                continue
            partition_key = f"{workspace}/{slug}"
            cursor_value = state.get(partition_key, {}).get(self.cursor_field)
            yield {
                "workspace": workspace,
                "slug": slug,
                "partition_key": partition_key,
                "cursor_value": cursor_value,
            }

    # ------------------------------------------------------------------
    # next_page_token: early exit on incremental cursor
    # ------------------------------------------------------------------

    def next_page_token(self, response, **kwargs):
        """Override to implement early exit on incremental cursor."""
        try:
            data = response.json()
        except ValueError:
            return None

        values = data.get("values", [])
        if values:
            last_updated = values[-1].get("updated_on", "")
            if last_updated:
                if self._current_cursor_value and last_updated < self._current_cursor_value:
                    return None
                if self._start_date and last_updated[:10] < self._start_date:
                    return None

        next_url = data.get("next")
        if next_url:
            return {"next_url": next_url}
        return None

    # ------------------------------------------------------------------
    # parse_response
    # ------------------------------------------------------------------

    def parse_response(self, response, stream_slice=None, **kwargs):
        self._check_near_limit(response)

        if response.status_code == 404:
            s = stream_slice or {}
            logger.warning(f"Skipping PRs for {s.get('workspace')}/{s.get('slug')} (404)")
            return

        data = response.json()
        values = data.get("values", [])
        s = stream_slice or {}
        workspace = s.get("workspace", "")
        slug = s.get("slug", "")
        cursor_value = s.get("cursor_value")
        self._current_cursor_value = cursor_value

        for pr in values:
            pr_id = pr.get("id")
            updated_on = pr.get("updated_on", "")

            # Skip records older than cursor for incremental
            if cursor_value and updated_on and updated_on <= cursor_value:
                continue
            # Skip records older than start_date on first sync
            if self._start_date and updated_on and updated_on[:10] < self._start_date:
                continue

            author = pr.get("author") or {}
            source_branch = (pr.get("source") or {}).get("branch") or {}
            dest_branch = (pr.get("destination") or {}).get("branch") or {}
            merge_commit = pr.get("merge_commit") or {}
            closed_by = pr.get("closed_by") or {}

            # Extract approvals from participants
            participants = pr.get("participants") or []
            reviewers = []
            for p in participants:
                user = p.get("user") or {}
                reviewers.append({
                    "display_name": user.get("display_name"),
                    "uuid": user.get("uuid"),
                    "nickname": user.get("nickname"),
                    "role": p.get("role"),
                    "approved": p.get("approved", False),
                    "state": p.get("state"),
                })

            # Requested reviewers (users explicitly asked to review)
            requested_reviewers = []
            for r in (pr.get("reviewers") or []):
                requested_reviewers.append({
                    "display_name": r.get("display_name"),
                    "uuid": r.get("uuid"),
                    "nickname": r.get("nickname"),
                })

            comment_count = pr.get("comment_count", 0)
            task_count = pr.get("task_count", 0)

            record = {
                "unique_key": _make_unique_key(
                    self._tenant_id, self._source_id, workspace, slug, str(pr_id),
                ),
                "id": pr_id,
                "title": pr.get("title"),
                "description": pr.get("description"),
                "state": pr.get("state"),
                "created_on": pr.get("created_on"),
                "updated_on": updated_on,
                "author_display_name": author.get("display_name"),
                "author_uuid": author.get("uuid"),
                "author_nickname": author.get("nickname"),
                "source_branch": source_branch.get("name"),
                "destination_branch": dest_branch.get("name"),
                "merge_commit_hash": merge_commit.get("hash"),
                "close_source_branch": pr.get("close_source_branch"),
                "closed_by_display_name": closed_by.get("display_name"),
                "closed_by_uuid": closed_by.get("uuid"),
                "comment_count": comment_count,
                "task_count": task_count,
                "participants": reviewers,
                "requested_reviewers": requested_reviewers,
                "workspace": workspace,
                "repo_slug": slug,
            }
            yield self._add_envelope(record)

            # Build child slice cache incrementally
            cache_key = (workspace, slug, pr_id)
            self._child_slice_cache[cache_key] = {
                "pr_id": pr_id,
                "updated_on": updated_on,
                "comment_count": comment_count,
                "workspace": workspace,
                "repo_slug": slug,
            }

    # ------------------------------------------------------------------
    # get_child_slices: minimal PR metadata for child streams
    # ------------------------------------------------------------------

    def get_child_slices(self) -> list:
        """Return minimal PR metadata for child streams to build slices from."""
        if self._child_slice_cache:
            return list(self._child_slice_cache.values())
        # Fallback: trigger read if not yet populated
        list(self.read_records(sync_mode=None))
        logger.info(f"PR child-slice cache: {len(self._child_slice_cache)} PRs")
        return list(self._child_slice_cache.values())

    # ------------------------------------------------------------------
    # get_updated_state: per-repo cursor
    # ------------------------------------------------------------------

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = f"{latest_record.get('workspace', '')}/{latest_record.get('repo_slug', '')}"
        if partition_key in self._partitions_with_errors:
            return current_stream_state

        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(self.cursor_field, "")
        if record_cursor > current_cursor:
            current_stream_state[partition_key] = {self.cursor_field: record_cursor}

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
                "id": {"type": ["null", "integer"]},
                "title": {"type": ["null", "string"]},
                "description": {"type": ["null", "string"]},
                "state": {"type": ["null", "string"]},
                "created_on": {"type": ["null", "string"]},
                "updated_on": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "author_nickname": {"type": ["null", "string"]},
                "source_branch": {"type": ["null", "string"]},
                "destination_branch": {"type": ["null", "string"]},
                "merge_commit_hash": {"type": ["null", "string"]},
                "close_source_branch": {"type": ["null", "boolean"]},
                "closed_by_display_name": {"type": ["null", "string"]},
                "closed_by_uuid": {"type": ["null", "string"]},
                "comment_count": {"type": ["null", "integer"]},
                "task_count": {"type": ["null", "integer"]},
                "participants": {"type": ["null", "array"]},
                "requested_reviewers": {"type": ["null", "array"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }

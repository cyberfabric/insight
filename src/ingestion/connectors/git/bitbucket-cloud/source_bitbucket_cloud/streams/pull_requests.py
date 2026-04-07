"""Bitbucket Cloud pull requests stream (REST, incremental by updated_on)."""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

import requests as req

from source_bitbucket_cloud.clients.auth import rest_headers
from source_bitbucket_cloud.clients.concurrent import retry_request
from source_bitbucket_cloud.streams.base import (
    BitbucketCloudRestStream,
    _is_fatal,
    _make_unique_key,
    _now_iso,
    check_rest_response,
)
from source_bitbucket_cloud.streams.repositories import RepositoriesStream

logger = logging.getLogger("airbyte")

API_BASE = "https://api.bitbucket.org/2.0"


class PullRequestsStream(BitbucketCloudRestStream):
    """Fetches pull requests per repository via REST API, incremental by updated_on.

    API: GET /repositories/{workspace}/{repo_slug}/pullrequests
         ?state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED
         &sort=-updated_on

    Sorted descending by updated_on for early-exit when reaching the cursor.
    State: per-partition ``{workspace}/{repo}`` with ``updated_on`` cursor.
    """

    name = "pull_requests"
    cursor_field = "updated_on"
    use_cache = True  # Reviews stream uses this as parent

    def __init__(
        self,
        parent: RepositoriesStream,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._parent = parent
        self._partitions_with_errors: set = set()
        self._child_slice_cache: Optional[list] = None

    # ------------------------------------------------------------------
    # Child-slice cache (for reviews stream)
    # ------------------------------------------------------------------

    def get_child_slices(self) -> list:
        """Return minimal PR metadata for child streams to build slices from.

        Intentionally reads ALL PRs (sync_mode=None, no stream_state) because
        child streams (reviews, comments, pr_commits, file_changes) need the
        full PR set for slice construction. Called after the parent's
        incremental sync populates the CDK cache. Results are cached here
        to avoid redundant reads.
        """
        if self._child_slice_cache is not None:
            return self._child_slice_cache

        temp = []
        for record in self.read_records(sync_mode=None):
            temp.append({
                "workspace": record.get("repo_owner", ""),
                "repo_slug": record.get("repo_name", ""),
                "pr_id": record.get("database_id"),
                "updated_on": record.get("updated_on", ""),
                "comment_count": record.get("comment_count"),
                "task_count": record.get("task_count"),
                "participants": record.get("participants", []),
            })
        self._child_slice_cache = temp
        logger.info(
            f"PR child-slice cache: {len(temp)} PRs cached "
            f"({len(temp) * 120 // 1024}KB est)"
        )
        return self._child_slice_cache

    # ------------------------------------------------------------------
    # Slices
    # ------------------------------------------------------------------

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        repos_skipped = 0
        repos_total = 0

        for record in self._parent.read_records(sync_mode=None):
            workspace = record.get("workspace", "")
            repo_slug = record.get("slug", "")
            if not (workspace and repo_slug):
                continue
            repos_total += 1

            # Repo freshness gate: skip if updated_on unchanged
            updated_on = record.get("updated_on", "")
            repo_state_key = f"_repo:{workspace}/{repo_slug}"
            stored_updated_on = state.get(repo_state_key, {}).get("updated_on", "")
            if updated_on and stored_updated_on and updated_on <= stored_updated_on:
                repos_skipped += 1
                logger.debug(
                    f"PR freshness: skipping {workspace}/{repo_slug} "
                    f"(updated_on unchanged)"
                )
                continue

            # Eagerly persist updated_on so repos with zero PRs are still
            # marked as seen and won't be re-traversed on the next sync.
            if updated_on:
                state[repo_state_key] = {"updated_on": updated_on}

            partition_key = f"{workspace}/{repo_slug}"
            cursor_value = state.get(partition_key, {}).get(self.cursor_field)
            yield {
                "workspace": workspace,
                "repo_slug": repo_slug,
                "partition_key": partition_key,
                "cursor_value": cursor_value,
                "repo_updated_on": updated_on,
            }

        if repos_skipped:
            logger.info(
                f"PR freshness: {repos_total - repos_skipped}/{repos_total} repos "
                f"need PR sync ({repos_skipped} skipped, unchanged)"
            )

    # ------------------------------------------------------------------
    # CDK hooks — manual REST fetching
    # ------------------------------------------------------------------

    def _path(self, **kwargs) -> str:
        # Not used — we drive fetching via read_records
        return ""

    def read_records(
        self,
        sync_mode=None,
        stream_slice=None,
        stream_state=None,
        **kwargs,
    ) -> Iterable[Mapping[str, Any]]:
        if stream_slice is None:
            for repo_slice in self.stream_slices(stream_state=stream_state):
                yield from self._fetch_prs_for_repo(repo_slice)
        else:
            yield from self._fetch_prs_for_repo(stream_slice)

    # ------------------------------------------------------------------
    # Manual REST fetch with pagination + early-exit
    # ------------------------------------------------------------------

    def _do_rest_get(self, url: str, context: str = "") -> req.Response:
        """Single GET with throttle, rate-limit update, and retry."""

        def _call():
            self._rate_limiter.wait_if_needed("rest")
            resp = req.get(
                url,
                headers=rest_headers(self._email, self._token),
                timeout=30,
            )
            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            self._rate_limiter.wait_if_needed("rest")
            if not check_rest_response(resp, context):
                return resp
            return resp

        return retry_request(_call, context=context)

    def _fetch_prs_for_repo(
        self,
        stream_slice: Mapping[str, Any],
    ) -> Iterable[Mapping[str, Any]]:
        """Paginate PRs sorted by -updated_on, early-exit on cursor."""
        workspace = stream_slice.get("workspace", "")
        repo_slug = stream_slice.get("repo_slug", "")
        cursor_value = stream_slice.get("cursor_value")
        repo_updated_on = stream_slice.get("repo_updated_on", "")

        url: str | None = (
            f"{API_BASE}/repositories/{workspace}/{repo_slug}/pullrequests"
            f"?state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED"
            f"&sort=-updated_on&pagelen=50"
        )
        context = f"PRs {workspace}/{repo_slug}"
        page = 0

        while url:
            page += 1
            try:
                resp = self._do_rest_get(url, context=f"{context} page {page}")
            except Exception as exc:
                if _is_fatal(exc):
                    raise
                logger.error(f"PR fetch error for {context}: {exc}")
                partition_key = f"{workspace}/{repo_slug}"
                self._partitions_with_errors.add(partition_key)
                return

            if resp.status_code in (404, 409):
                logger.warning(f"Skipping {context} ({resp.status_code})")
                return

            body = resp.json()
            prs = body.get("values", [])
            if not prs:
                return

            early_exit = False
            for pr in prs:
                pr_updated_on = pr.get("updated_on", "")

                # Early-exit: stop when we reach already-seen data
                if cursor_value and pr_updated_on and pr_updated_on <= cursor_value:
                    early_exit = True
                    break

                pr_id = pr.get("id")
                pr_id_str = str(pr_id) if pr_id is not None else ""

                author = pr.get("author") or {}
                source = pr.get("source") or {}
                destination = pr.get("destination") or {}
                source_branch = source.get("branch") or {}
                dest_branch = destination.get("branch") or {}
                merge_commit = pr.get("merge_commit") or {}

                # Determine closed_on: non-OPEN states have a close timestamp
                pr_state = pr.get("state", "")
                closed_on = None
                if pr_state in ("MERGED", "DECLINED", "SUPERSEDED"):
                    closed_on = pr_updated_on or None

                # Cache participants for reviews stream
                participants = pr.get("participants") or []
                participants_out = []
                for p in participants:
                    user = p.get("user") or {}
                    participants_out.append({
                        "display_name": user.get("display_name"),
                        "uuid": user.get("uuid"),
                        "nickname": user.get("nickname"),
                        "role": p.get("role"),
                        "approved": p.get("approved"),
                        "state": p.get("state"),
                    })

                pk_parts = [workspace, repo_slug, pr_id_str]
                record = {
                    "unique_key": _make_unique_key(self._tenant_id, self._source_id, *pk_parts),
                    "database_id": pr_id,
                    "title": pr.get("title"),
                    "body": pr.get("description"),
                    "state": pr_state,
                    "created_on": pr.get("created_on"),
                    "updated_on": pr_updated_on,
                    "closed_on": closed_on,
                    "author_display_name": author.get("display_name"),
                    "author_uuid": author.get("uuid"),
                    "author_nickname": author.get("nickname"),
                    "head_ref": source_branch.get("name"),
                    "base_ref": dest_branch.get("name"),
                    "merge_commit_hash": merge_commit.get("hash"),
                    "close_source_branch": pr.get("close_source_branch"),
                    "comment_count": pr.get("comment_count"),
                    "task_count": pr.get("task_count"),
                    "participants": participants_out,
                    "repo_owner": workspace,
                    "repo_name": repo_slug,
                    "repo_updated_on": repo_updated_on,
                }
                yield self._add_envelope(record)

            if early_exit:
                logger.debug(f"Early exit on cursor date for {context}")
                return

            url = body.get("next")

    # ------------------------------------------------------------------
    # State
    # ------------------------------------------------------------------

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = (
            f"{latest_record.get('repo_owner', '')}/"
            f"{latest_record.get('repo_name', '')}"
        )
        if partition_key in self._partitions_with_errors:
            return current_stream_state

        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(
            self.cursor_field, ""
        )
        if record_cursor > current_cursor:
            current_stream_state[partition_key] = {self.cursor_field: record_cursor}

        # Repo updated_on for freshness gate
        repo_updated_on = latest_record.get("repo_updated_on", "")
        if repo_updated_on:
            workspace = latest_record.get("repo_owner", "")
            repo_slug = latest_record.get("repo_name", "")
            repo_state_key = f"_repo:{workspace}/{repo_slug}"
            current_stream_state[repo_state_key] = {"updated_on": repo_updated_on}

        return current_stream_state

    # ------------------------------------------------------------------
    # Schema
    # ------------------------------------------------------------------

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
                "database_id": {"type": ["null", "integer"]},
                "title": {"type": ["null", "string"]},
                "body": {"type": ["null", "string"]},
                "state": {"type": ["null", "string"]},
                "created_on": {"type": ["null", "string"]},
                "updated_on": {"type": ["null", "string"]},
                "closed_on": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "author_nickname": {"type": ["null", "string"]},
                "head_ref": {"type": ["null", "string"]},
                "base_ref": {"type": ["null", "string"]},
                "merge_commit_hash": {"type": ["null", "string"]},
                "close_source_branch": {"type": ["null", "boolean"]},
                "comment_count": {"type": ["null", "integer"]},
                "task_count": {"type": ["null", "integer"]},
                "participants": {
                    "type": ["null", "array"],
                    "items": {
                        "type": "object",
                        "properties": {
                            "display_name": {"type": ["null", "string"]},
                            "uuid": {"type": ["null", "string"]},
                            "nickname": {"type": ["null", "string"]},
                            "role": {"type": ["null", "string"]},
                            "approved": {"type": ["null", "boolean"]},
                            "state": {"type": ["null", "string"]},
                        },
                    },
                },
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

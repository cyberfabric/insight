"""Bitbucket Cloud file changes stream — per-commit diffstat.

CDK-native: stream_slices yields one slice per commit (non-merge only,
deduplicated). Commit metadata is read from a temp file written by the
commits stream — zero extra API calls, near-zero memory.
CDK handles pagination (next URL), retry, and backoff for each slice.
"""

import logging
import os
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_bitbucket_cloud.streams.base import (
    BitbucketAuthError,
    BitbucketCloudRestStream,
    _make_unique_key,
    _now_iso,
)

logger = logging.getLogger("airbyte")


class FileChangesStream(BitbucketCloudRestStream):
    """File changes per commit (all branches, non-merge only, deduplicated).

    Data source: GET /repositories/{workspace}/{slug}/diffstat/{sha}
    Commit list comes from a temp TSV written by CommitsStream during its
    parse_response — no re-read, no extra API calls, near-zero memory.
    """

    name = "file_changes"

    def __init__(self, parent, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent

    def _path(self, stream_slice=None, **kwargs) -> str:
        s = stream_slice or {}
        workspace = s.get("workspace", "")
        slug = s.get("slug", "")
        sha = s.get("sha", "")
        return f"repositories/{workspace}/{slug}/diffstat/{sha}"

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        meta_path = self._parent.get_commit_meta_path()
        total = 0
        skipped_merge = 0

        if not os.path.exists(meta_path):
            logger.warning(f"Commit metadata file not found: {meta_path}, skipping file_changes")
            return

        with open(meta_path, "r") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t", 4)
                if len(parts) < 5:
                    continue
                sha, workspace, slug, committed_date, parent_count_str = parts
                parent_count = int(parent_count_str) if parent_count_str.isdigit() else 0

                # Skip merge commits
                if parent_count > 1:
                    skipped_merge += 1
                    continue

                total += 1
                yield {
                    "workspace": workspace,
                    "slug": slug,
                    "sha": sha,
                    "committed_date": committed_date,
                }

        logger.info(f"File changes: {total} commits to fetch ({skipped_merge} merge skipped)")

    def request_params(
        self,
        next_page_token: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> MutableMapping[str, Any]:
        if next_page_token:
            return {}
        return {"pagelen": "100"}

    def parse_response(self, response, stream_slice=None, **kwargs):
        self._check_near_limit(response)

        s = stream_slice or {}
        workspace = s.get("workspace", "")
        slug = s.get("slug", "")

        if response.status_code == 404:
            logger.warning(
                f"Skipping {workspace}/{slug} file_changes (404): "
                f"sha={s.get('sha', '?')[:8]}"
            )
            return

        data = response.json()
        values = data.get("values", [])
        sha = s.get("sha", "")
        committed_date = s.get("committed_date", "")

        for entry in values:
            # Bitbucket diffstat: new.path for added/modified, old.path for deleted
            new_file = entry.get("new") or {}
            old_file = entry.get("old") or {}
            filename = new_file.get("path") or old_file.get("path") or ""

            if not filename:
                continue

            status = entry.get("status", "")
            previous_filename = old_file.get("path") if status == "renamed" else None

            pk_parts = [workspace, slug, sha, filename]
            yield {
                "unique_key": _make_unique_key(self._tenant_id, self._source_id, *pk_parts),
                "tenant_id": self._tenant_id,
                "source_id": self._source_id,
                "data_source": "insight_bitbucket_cloud",
                "collected_at": _now_iso(),
                "source_type": "commit",
                "sha": sha,
                "filename": filename,
                "status": status,
                "additions": entry.get("lines_added"),
                "deletions": entry.get("lines_removed"),
                "previous_filename": previous_filename,
                "committed_date": committed_date,
                "workspace": workspace,
                "repo_slug": slug,
            }

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        s = stream_slice or {}
        if not (s.get("workspace") and s.get("slug") and s.get("sha")):
            return
        try:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice,
                stream_state=stream_state, **kwargs,
            )
        except BitbucketAuthError:
            raise
        except Exception as exc:
            logger.error(
                f"Failed file_changes for {s.get('workspace')}/{s.get('slug')}/"
                f"{s.get('sha', '?')[:8]}: {exc}"
            )
            raise

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
                "source_type": {"type": "string"},
                "sha": {"type": ["null", "string"]},
                "filename": {"type": ["null", "string"]},
                "status": {"type": ["null", "string"]},
                "additions": {"type": ["null", "integer"]},
                "deletions": {"type": ["null", "integer"]},
                "previous_filename": {"type": ["null", "string"]},
                "committed_date": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }

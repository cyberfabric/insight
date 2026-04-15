"""GitHub file changes stream -- per-commit file changes.

CDK-native: stream_slices yields one slice per commit (non-merge only,
deduplicated). Commit metadata is read from a temp file written by the
commits stream — zero extra API calls, near-zero memory.
CDK handles pagination (Link header), retry, and backoff for each slice.
"""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_github_v2.streams.base import (
    GitHubAuthError,
    GitHubRestStream,
    _make_unique_key,
    _now_iso,
)

logger = logging.getLogger("airbyte")


class FileChangesStream(GitHubRestStream):
    """File changes per commit (all branches, non-merge only, deduplicated).

    Data source: GET /repos/{owner}/{repo}/commits/{sha} -> files array.
    Commit list comes from a temp TSV written by CommitsStream during its
    parse_response — no re-read, no extra API calls, near-zero memory.
    """

    name = "file_changes"

    def __init__(self, parent, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent

    def _path(self, stream_slice=None, **kwargs) -> str:
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        sha = s.get("sha", "")
        return f"repos/{owner}/{repo}/commits/{sha}"

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        meta_path = self._parent.get_commit_meta_path()
        total = 0
        skipped_merge = 0

        # The TSV only contains commits the commits stream emitted this sync
        # (already incremental, already deduplicated). No additional cursor
        # filtering here — that would break force-push scenarios where the
        # commits stream re-emits old commits with older committed_at.
        with open(meta_path, "r") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t", 4)
                if len(parts) < 5:
                    continue
                sha, owner, repo, committed_at, parent_count_str = parts
                parent_count = int(parent_count_str) if parent_count_str.isdigit() else 0

                # Skip merge commits
                if parent_count > 1:
                    skipped_merge += 1
                    continue

                total += 1
                yield {
                    "owner": owner,
                    "repo": repo,
                    "sha": sha,
                    "committed_date": committed_at,
                }

        logger.info(f"File changes: {total} commits to fetch ({skipped_merge} merge skipped)")

    def request_params(
        self,
        next_page_token: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> MutableMapping[str, Any]:
        if next_page_token:
            return {}
        return {"per_page": "100"}

    def parse_response(self, response, stream_slice=None, **kwargs):
        """CDK calls this per page. Extract files from commit response."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")

        if not self._guard_response(response):
            return

        data = response.json()
        files = data.get("files", [])
        sha = s.get("sha", "")
        committed_at = s.get("committed_date", "")

        for f in files:
            filename = f.get("filename", "")
            pk_parts = [owner, repo, sha, filename]
            yield {
                "unique_key": _make_unique_key(self._tenant_id, self._source_id, *pk_parts),
                "tenant_id": self._tenant_id,
                "source_id": self._source_id,
                "data_source": "insight_github",
                "collected_at": _now_iso(),
                "source_type": "commit",
                "sha": sha,
                "filename": filename,
                "status": f.get("status"),
                "additions": f.get("additions"),
                "deletions": f.get("deletions"),
                "changes": f.get("changes"),
                "previous_filename": f.get("previous_filename"),
                "patch": f.get("patch"),
                "committed_date": committed_at,
                "repo_owner": owner,
                "repo_name": repo,
            }

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        s = stream_slice or {}
        if not (s.get("owner") and s.get("repo") and s.get("sha")):
            return
        try:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice,
                stream_state=stream_state, **kwargs,
            )
        except GitHubAuthError:
            raise
        except Exception as exc:
            logger.error(f"Failed file_changes for {s.get('owner')}/{s.get('repo')}/{s.get('sha', '?')[:8]}: {exc}")
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
                "changes": {"type": ["null", "integer"]},
                "previous_filename": {"type": ["null", "string"]},
                "patch": {"type": ["null", "string"]},
                "committed_date": {"type": ["null", "string"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

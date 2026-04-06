"""Bitbucket Cloud branches stream (REST, full refresh, child of repositories)."""

import logging
from typing import Any, Iterable, Mapping, Optional

from source_bitbucket_cloud.streams.base import (
    BitbucketCloudRestStream,
    _make_pk,
    check_rest_response,
)
from source_bitbucket_cloud.streams.repositories import RepositoriesStream

logger = logging.getLogger("airbyte")


class BranchesStream(BitbucketCloudRestStream):
    """Fetches branches for each repository.

    API: GET /repositories/{workspace}/{repo_slug}/refs/branches
    """

    name = "branches"

    def __init__(self, parent: RepositoriesStream, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._cached_records: Optional[list] = None

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        workspace = s.get("workspace", "")
        repo_slug = s.get("repo_slug", "")
        if not workspace or not repo_slug:
            raise ValueError("BranchesStream._path() called without workspace/repo_slug in stream_slice")
        return f"repositories/{workspace}/{repo_slug}/refs/branches"

    def stream_slices(self, **kwargs) -> Iterable[Optional[Mapping[str, Any]]]:
        for repo in self._parent.get_child_records():
            workspace = repo.get("workspace", "")
            repo_slug = repo.get("slug", "")
            default_branch = repo.get("default_branch", "")
            if workspace and repo_slug:
                yield {
                    "workspace": workspace,
                    "repo_slug": repo_slug,
                    "default_branch": default_branch,
                }

    def read_records(self, sync_mode=None, stream_slice=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_slice is None:
            if self._cached_records is not None:
                yield from self._cached_records
                return
            temp = []
            for repo_slice in self.stream_slices():
                for record in super().read_records(sync_mode=sync_mode, stream_slice=repo_slice, **kwargs):
                    temp.append(record)
            self._cached_records = temp
            yield from self._cached_records
        else:
            yield from super().read_records(sync_mode=sync_mode, stream_slice=stream_slice, **kwargs)

    def parse_response(self, response, stream_slice=None, **kwargs):
        self._update_rate_limit(response)
        self._rate_limiter.wait_if_needed("rest")
        s = stream_slice or {}
        workspace = s.get("workspace", "")
        repo_slug = s.get("repo_slug", "")
        if not check_rest_response(response, f"branches for {workspace}/{repo_slug}"):
            return
        data = response.json()
        branches = data.get("values", [])
        for branch in branches:
            branch_name = branch.get("name", "")
            target = branch.get("target") or {}

            record = {
                "name": branch_name,
                "head_sha": target.get("hash", ""),
                "target_date": target.get("date", ""),
                "target_author_raw": (target.get("author") or {}).get("raw", ""),
                "workspace": workspace,
                "repo_slug": repo_slug,
                "default_branch": s.get("default_branch", ""),
            }
            record["pk"] = _make_pk(
                self._tenant_id, self._source_instance_id,
                workspace, repo_slug, branch_name,
            )
            yield self._add_envelope(record)

    def get_child_records(self) -> list[dict]:
        """Return cached branch records for child streams (e.g. commits)."""
        if self._cached_records is None:
            list(self.read_records(sync_mode=None))
        return self._cached_records or []

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
                "name": {"type": ["null", "string"]},
                "head_sha": {"type": ["null", "string"]},
                "target_date": {"type": ["null", "string"]},
                "target_author_raw": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
                "default_branch": {"type": ["null", "string"]},
            },
        }

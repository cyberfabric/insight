"""Bitbucket Cloud repositories stream (REST, full refresh)."""

import json
import logging
from typing import Any, Iterable, List, Mapping, Optional

from source_bitbucket_cloud.streams.base import (
    BitbucketCloudRestStream,
    _make_pk,
    check_rest_response,
)

logger = logging.getLogger("airbyte")


class RepositoriesStream(BitbucketCloudRestStream):
    """Fetches all repositories for configured workspaces via REST API.

    API: GET /repositories/{workspace}
    """

    name = "repositories"
    use_cache = True

    def __init__(
        self,
        workspaces: list[str],
        skip_forks: bool = True,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._workspaces = workspaces
        self._skip_forks = skip_forks
        self._cached_records: Optional[list] = None

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        workspace = (stream_slice or {}).get("workspace", "")
        if not workspace:
            raise ValueError("RepositoriesStream._path() called without workspace in stream_slice")
        return f"repositories/{workspace}"

    def stream_slices(self, **kwargs) -> Iterable[Optional[Mapping[str, Any]]]:
        for workspace in self._workspaces:
            yield {"workspace": workspace}

    def read_records(self, sync_mode=None, stream_slice=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_slice is None:
            if self._cached_records is not None:
                yield from self._cached_records
                return
            temp = []
            for ws_slice in self.stream_slices():
                for record in super().read_records(sync_mode=sync_mode, stream_slice=ws_slice, **kwargs):
                    temp.append(record)
            self._cached_records = temp
            yield from self._cached_records
        else:
            yield from super().read_records(sync_mode=sync_mode, stream_slice=stream_slice, **kwargs)

    def parse_response(self, response, stream_slice=None, **kwargs):
        self._update_rate_limit(response)
        self._rate_limiter.wait_if_needed("rest")
        workspace = (stream_slice or {}).get("workspace", "")
        if not check_rest_response(response, f"repos for workspace {workspace}"):
            return
        data = response.json()
        repos = data.get("values", [])
        skipped = 0
        for repo in repos:
            if self._skip_forks and repo.get("parent") is not None:
                skipped += 1
                continue

            slug = repo.get("slug", "")
            mainbranch = repo.get("mainbranch") or {}

            record = {
                "uuid": repo.get("uuid", ""),
                "slug": slug,
                "name": repo.get("name", ""),
                "full_name": repo.get("full_name", ""),
                "is_private": repo.get("is_private"),
                "description": repo.get("description", ""),
                "language": repo.get("language", ""),
                "created_on": repo.get("created_on", ""),
                "updated_on": repo.get("updated_on", ""),
                "size": repo.get("size"),
                "default_branch": mainbranch.get("name", ""),
                "has_issues": repo.get("has_issues"),
                "has_wiki": repo.get("has_wiki"),
                "workspace": workspace,
                "metadata": json.dumps(repo),
            }
            record["pk"] = _make_pk(self._tenant_id, self._source_instance_id, workspace, slug)
            yield self._add_envelope(record)
        if skipped:
            logger.info(f"Repo filter: skipped {skipped} fork(s) in workspace {workspace}")

    def get_child_records(self) -> list[dict]:
        """Return cached repository records for child streams."""
        if self._cached_records is None:
            # Force a full read to populate cache
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
                "uuid": {"type": ["null", "string"]},
                "slug": {"type": ["null", "string"]},
                "name": {"type": ["null", "string"]},
                "full_name": {"type": ["null", "string"]},
                "is_private": {"type": ["null", "boolean"]},
                "description": {"type": ["null", "string"]},
                "language": {"type": ["null", "string"]},
                "created_on": {"type": ["null", "string"]},
                "updated_on": {"type": ["null", "string"]},
                "size": {"type": ["null", "integer"]},
                "default_branch": {"type": ["null", "string"]},
                "has_issues": {"type": ["null", "boolean"]},
                "has_wiki": {"type": ["null", "boolean"]},
                "workspace": {"type": "string"},
                "metadata": {"type": ["null", "string"]},
            },
        }

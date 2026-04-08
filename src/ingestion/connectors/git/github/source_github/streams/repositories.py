"""GitHub repositories stream (REST, full refresh)."""

import logging
from typing import Any, Iterable, List, Mapping, Optional

from source_github.streams.base import GitHubRestStream, _make_unique_key, check_rest_response

logger = logging.getLogger("airbyte")


class RepositoriesStream(GitHubRestStream):
    """Fetches all repositories for configured organizations via REST API."""

    name = "repositories"
    use_cache = True  # Other streams use this as parent

    def __init__(
        self,
        organizations: List[str],
        skip_archived: bool = True,
        skip_forks: bool = True,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._organizations = organizations
        self._skip_archived = skip_archived
        self._skip_forks = skip_forks
        self._cached_records: Optional[list] = None

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        org = (stream_slice or {}).get("organization", "")
        if not org:
            raise ValueError("RepositoriesStream._path() called without organization in stream_slice")
        return f"orgs/{org}/repos"

    def read_records(self, sync_mode=None, stream_slice=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_slice is None:
            if self._cached_records is not None:
                yield from self._cached_records
                return
            temp = []
            for org_slice in self.stream_slices():
                for record in super().read_records(sync_mode=sync_mode, stream_slice=org_slice, **kwargs):
                    temp.append(record)
            self._cached_records = temp
            yield from self._cached_records
        else:
            yield from super().read_records(sync_mode=sync_mode, stream_slice=stream_slice, **kwargs)

    def request_params(self, **kwargs) -> dict:
        return {"per_page": "100", "type": "all"}

    def stream_slices(self, **kwargs) -> Iterable[Optional[Mapping[str, Any]]]:
        for org in self._organizations:
            yield {"organization": org}

    def parse_response(self, response, stream_slice=None, **kwargs):
        self._update_rate_limit(response)
        self._rate_limiter.wait_if_needed("rest")
        org = (stream_slice or {}).get("organization", "")
        if not check_rest_response(response, f"repos for org {org}"):
            return
        repos = response.json()
        if not isinstance(repos, list):
            repos = [repos]
        skipped = 0
        for repo in repos:
            owner = repo.get("owner", {}).get("login", "")
            name = repo.get("name", "")
            if self._skip_archived and repo.get("archived"):
                skipped += 1
                continue
            if self._skip_forks and repo.get("fork"):
                skipped += 1
                continue
            repo["unique_key"] = _make_unique_key(self._tenant_id, self._source_id, owner, name)
            yield self._add_envelope(repo)
        if skipped:
            logger.info(f"Repo filter: skipped {skipped} repos (archived/fork) in org {org}")

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
                "name": {"type": ["null", "string"]},
                "full_name": {"type": ["null", "string"]},
                "private": {"type": ["null", "boolean"]},
                "description": {"type": ["null", "string"]},
                "fork": {"type": ["null", "boolean"]},
                "archived": {"type": ["null", "boolean"]},
                "language": {"type": ["null", "string"]},
                "default_branch": {"type": ["null", "string"]},
                "created_at": {"type": ["null", "string"]},
                "updated_at": {"type": ["null", "string"]},
                "pushed_at": {"type": ["null", "string"]},
                "stargazers_count": {"type": ["null", "integer"]},
                "forks_count": {"type": ["null", "integer"]},
                "watchers_count": {"type": ["null", "integer"]},
                "open_issues_count": {"type": ["null", "integer"]},
            },
        }

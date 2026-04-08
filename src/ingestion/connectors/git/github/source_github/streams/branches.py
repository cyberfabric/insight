"""GitHub branches stream (REST, full refresh, sub-stream of repositories)."""

from typing import Any, Iterable, List, Mapping, Optional

from source_github.streams.base import GitHubRestStream, _make_unique_key, check_rest_response
from source_github.streams.repositories import RepositoriesStream


class BranchesStream(GitHubRestStream):
    """Fetches branches for each repository."""

    name = "branches"

    def __init__(self, parent: RepositoriesStream, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._cached_records: Optional[list] = None

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        if not owner or not repo:
            raise ValueError("BranchesStream._path() called without owner/repo in stream_slice")
        return f"repos/{owner}/{repo}/branches"

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

    def stream_slices(self, **kwargs) -> Iterable[Optional[Mapping[str, Any]]]:
        for record in self._parent.read_records(sync_mode=None):
            owner = record.get("owner", {}).get("login", "")
            repo = record.get("name", "")
            default_branch = record.get("default_branch", "")
            pushed_at = record.get("pushed_at", "")
            if owner and repo:
                yield {"owner": owner, "repo": repo, "default_branch": default_branch, "pushed_at": pushed_at}

    def parse_response(self, response, stream_slice=None, **kwargs):
        self._update_rate_limit(response)
        self._rate_limiter.wait_if_needed("rest")
        owner = stream_slice["owner"]
        repo = stream_slice["repo"]
        if not check_rest_response(response, f"branches for {owner}/{repo}"):
            return
        branches = response.json()
        if not isinstance(branches, list):
            branches = [branches]
        owner = stream_slice["owner"]
        repo = stream_slice["repo"]
        for branch in branches:
            branch_name = branch.get("name", "")
            branch["unique_key"] = _make_unique_key(
                self._tenant_id, self._source_id,
                owner, repo, branch_name,
            )
            branch["repo_owner"] = owner
            branch["repo_name"] = repo
            branch["default_branch_name"] = stream_slice.get("default_branch", "")
            branch["pushed_at"] = stream_slice.get("pushed_at", "")
            yield self._add_envelope(branch)

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
                "name": {"type": ["null", "string"]},
                "commit": {"type": ["null", "object"]},
                "protected": {"type": ["null", "boolean"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

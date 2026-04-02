"""GitHub branches stream (REST, full refresh, sub-stream of repositories)."""

from typing import Any, Iterable, List, Mapping, Optional

from source_github.streams.base import GitHubRestStream, _make_pk, check_rest_response
from source_github.streams.repositories import RepositoriesStream


class BranchesStream(GitHubRestStream):
    """Fetches branches for each repository."""

    name = "branches"

    def __init__(self, parent: RepositoriesStream, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        if not owner or not repo:
            raise ValueError("BranchesStream._path() called without owner/repo in stream_slice")
        return f"repos/{owner}/{repo}/branches"

    def read_records(self, sync_mode=None, stream_slice=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_slice is None:
            # Called by child stream without a slice — iterate all repos
            for repo_slice in self.stream_slices():
                yield from super().read_records(sync_mode=sync_mode, stream_slice=repo_slice, **kwargs)
        else:
            yield from super().read_records(sync_mode=sync_mode, stream_slice=stream_slice, **kwargs)

    def stream_slices(self, **kwargs) -> Iterable[Optional[Mapping[str, Any]]]:
        for record in self._parent.read_records(sync_mode=None):
            owner = record.get("owner", {}).get("login", "")
            repo = record.get("name", "")
            default_branch = record.get("default_branch", "")
            if owner and repo:
                yield {"owner": owner, "repo": repo, "default_branch": default_branch}

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
            branch["pk"] = _make_pk(
                self._tenant_id, self._source_instance_id,
                owner, repo, branch_name,
            )
            branch["_owner"] = owner
            branch["_repo"] = repo
            branch["_default_branch"] = stream_slice.get("default_branch", "")
            yield self._add_envelope(branch)

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
                "commit": {"type": ["null", "object"]},
                "protected": {"type": ["null", "boolean"]},
                "_owner": {"type": "string"},
                "_repo": {"type": "string"},
            },
        }

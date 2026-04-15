"""GitHub branches stream (REST, full refresh, child of repositories)."""

import json
import logging
import os
import tempfile
from typing import Any, Iterable, Mapping, Optional

from source_github_v2.streams.base import GitHubRestStream, _make_unique_key
from source_github_v2.streams.repositories import RepositoriesStream

logger = logging.getLogger("airbyte")


class BranchesStream(GitHubRestStream):
    """Fetches branches for each repository."""

    name = "branches"
    use_cache = True

    def __init__(self, parent: RepositoriesStream, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._child_records_file = tempfile.NamedTemporaryFile(
            mode="w", prefix="insight_branches_", suffix=".jsonl", delete=False,
        )
        self._child_records_path = self._child_records_file.name

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        if not owner or not repo:
            raise ValueError("BranchesStream._path() called without owner/repo in stream_slice")
        return f"repos/{owner}/{repo}/branches"

    def stream_slices(self, **kwargs) -> Iterable[Optional[Mapping[str, Any]]]:
        for record in self._parent.get_child_records():
            owner = record.get("owner", "")
            repo = record.get("name", "")
            default_branch = record.get("default_branch", "")
            pushed_at = record.get("pushed_at", "")
            if owner and repo:
                yield {
                    "owner": owner,
                    "repo": repo,
                    "default_branch": default_branch,
                    "pushed_at": pushed_at,
                }

    def parse_response(self, response, stream_slice=None, **kwargs):
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        if not self._guard_response(response):
            return
        branches = response.json()
        if not isinstance(branches, list):
            branches = [branches]
        for branch in branches:
            branch_name = branch.get("name", "")
            branch["unique_key"] = _make_unique_key(
                self._tenant_id, self._source_id, owner, repo, branch_name,
            )
            branch["repo_owner"] = owner
            branch["repo_name"] = repo
            branch["default_branch_name"] = s.get("default_branch", "")
            branch["pushed_at"] = s.get("pushed_at", "")
            # Write minimal child data to disk for commits stream
            head_sha = (branch.get("commit") or {}).get("sha", "")
            self._child_records_file.write(json.dumps({
                "name": branch_name,
                "repo_owner": owner,
                "repo_name": repo,
                "default_branch": s.get("default_branch", ""),
                "pushed_at": s.get("pushed_at", ""),
                "commit": {"sha": head_sha},
            }, separators=(",", ":")) + "\n")
            yield self._add_envelope(branch)

    def get_child_records(self) -> Iterable:
        """Yield branch records from disk. Zero memory, zero API calls."""
        if self._child_records_file and not self._child_records_file.closed:
            self._child_records_file.close()
        if not os.path.exists(self._child_records_path):
            return
        with open(self._child_records_path, "r") as f:
            for line in f:
                line = line.rstrip("\n")
                if line:
                    yield json.loads(line)

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
                "default_branch_name": {"type": ["null", "string"]},
                "pushed_at": {"type": ["null", "string"]},
            },
        }

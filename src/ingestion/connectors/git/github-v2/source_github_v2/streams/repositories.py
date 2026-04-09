"""GitHub repositories stream (REST, full refresh)."""

import atexit
import json
import logging
import os
import tempfile
from typing import Any, Iterable, Mapping, Optional

from source_github_v2.streams.base import GitHubRestStream, _make_unique_key

logger = logging.getLogger("airbyte")


class RepositoriesStream(GitHubRestStream):
    """Fetches all repositories for configured organizations via REST API."""

    name = "repositories"
    use_cache = True

    def __init__(
        self,
        organizations: list[str],
        skip_archived: bool = True,
        skip_forks: bool = True,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._organizations = organizations
        self._skip_archived = skip_archived
        self._skip_forks = skip_forks
        self._child_records_file = tempfile.NamedTemporaryFile(
            mode="w", prefix="insight_repos_", suffix=".jsonl", delete=False,
        )
        self._child_records_path = self._child_records_file.name
        atexit.register(lambda p=self._child_records_path: os.unlink(p) if os.path.exists(p) else None)

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        org = (stream_slice or {}).get("org", "")
        if not org:
            raise ValueError("RepositoriesStream._path() called without org in stream_slice")
        return f"orgs/{org}/repos"

    def request_params(self, **kwargs) -> dict:
        return {"per_page": "100", "type": "all"}

    def stream_slices(self, **kwargs) -> Iterable[Optional[Mapping[str, Any]]]:
        for org in self._organizations:
            yield {"org": org}

    def parse_response(self, response, stream_slice=None, **kwargs):
        org = (stream_slice or {}).get("org", "")
        if response.status_code in (404, 409):
            logger.warning(f"Skipping repos for org {org} ({response.status_code})")
            return
        repos = response.json()
        if not isinstance(repos, list):
            repos = [repos]
        skipped = 0
        for repo in repos:
            if self._skip_archived and repo.get("archived"):
                skipped += 1
                continue
            if self._skip_forks and repo.get("fork"):
                skipped += 1
                continue

            owner = repo.get("owner", {}).get("login", "")
            repo_name = repo.get("name", "")
            repo["unique_key"] = _make_unique_key(
                self._tenant_id, self._source_id, owner, repo_name,
            )
            repo["repo_owner"] = owner
            record = self._add_envelope(repo)
            # Write minimal child data to disk for child streams
            self._child_records_file.write(json.dumps({
                "owner": owner,
                "name": repo_name,
                "default_branch": repo.get("default_branch"),
                "pushed_at": repo.get("pushed_at"),
            }, separators=(",", ":")) + "\n")
            yield record
        if skipped:
            logger.info(f"Repo filter: skipped {skipped} repos (archived/fork) in org {org}")

    def get_child_records(self) -> Iterable:
        """Yield repo records from disk. Zero memory, zero API calls."""
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
                "repo_owner": {"type": "string"},
                "name": {"type": ["null", "string"]},
                "full_name": {"type": ["null", "string"]},
                "private": {"type": ["null", "boolean"]},
                "description": {"type": ["null", "string"]},
                "language": {"type": ["null", "string"]},
                "created_at": {"type": ["null", "string"]},
                "updated_at": {"type": ["null", "string"]},
                "pushed_at": {"type": ["null", "string"]},
                "size": {"type": ["null", "integer"]},
                "default_branch": {"type": ["null", "string"]},
                "has_issues": {"type": ["null", "boolean"]},
                "has_wiki": {"type": ["null", "boolean"]},
                "fork": {"type": ["null", "boolean"]},
                "archived": {"type": ["null", "boolean"]},
            },
        }

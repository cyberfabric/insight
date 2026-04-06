"""GitHub file changes stream — PR files + direct-push files in one table."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_github.clients.auth import rest_headers
from source_github.clients.concurrent import fetch_parallel_with_slices, retry_request
from source_github.streams.base import GitHubRestStream, _is_fatal, _make_pk, _make_unique_key, _now_iso, check_rest_response
from source_github.streams.commits import CommitsStream
from source_github.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")


class FileChangesStream(GitHubRestStream):
    """Unified file changes from PRs and direct pushes.

    Two data sources in one table:
    - PR files: GET /repos/{owner}/{repo}/pulls/{number}/files (per PR)
    - Direct-push files: GET /repos/{owner}/{repo}/commits/{sha} (default branch, non-merge only)

    PR files have pr_number set; direct-push files have pr_number = null.
    source_type discriminator: "pr" or "direct_push".
    """

    name = "file_changes"
    cursor_field = "pr_updated_at"

    def __init__(
        self,
        pr_parent: PullRequestsStream,
        commits_parent: CommitsStream,
        max_workers: int = 5,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._pr_parent = pr_parent
        self._commits_parent = commits_parent
        self._max_workers = max_workers
        self._state: MutableMapping[str, Any] = {}

    def _path(self, **kwargs) -> str:
        return ""

    @property
    def state(self) -> MutableMapping[str, Any]:
        return self._state

    @state.setter
    def state(self, value: MutableMapping[str, Any]):
        self._state = value or {}

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        return self._state

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_state:
            self._state = stream_state

        # Phase 1: PR files
        pr_slices = list(self._pr_file_slices())
        if pr_slices:
            logger.info(f"File changes: fetching PR files for {len(pr_slices)} PRs")
            for result in fetch_parallel_with_slices(self._fetch_pr_files, pr_slices, self._max_workers):
                if result.error is not None:
                    if _is_fatal(result.error):
                        raise result.error
                    logger.warning(f"Skipping PR file slice {result.slice.get('partition_key', '?')}: {result.error}")
                    continue
                yield from result.records
                self._advance_pr_state(result.slice)

        # Phase 2: Direct-push files (default branch, non-merge commits only)
        direct_slices = list(self._direct_push_slices())
        if direct_slices:
            logger.info(f"File changes: fetching direct-push files for {len(direct_slices)} commits")
            for result in fetch_parallel_with_slices(self._fetch_direct_push_files, direct_slices, self._max_workers):
                if result.error is not None:
                    if _is_fatal(result.error):
                        raise result.error
                    logger.warning(f"Skipping commit file slice {result.slice.get('partition_key', '?')}: {result.error}")
                    continue
                yield from result.records
                self._advance_direct_state(result.slice)

    # --- Slice generators ---

    def _pr_file_slices(self) -> Iterable[Mapping[str, Any]]:
        """Yield one slice per PR that needs file sync."""
        total = 0
        skipped = 0
        for pr in self._pr_parent.get_child_slices():
            owner = pr.get("repo_owner", "")
            repo = pr.get("repo_name", "")
            pr_number = pr.get("number")
            pr_database_id = pr.get("database_id")
            pr_updated_at = pr.get("updated_at", "")
            if not (owner and repo and pr_number):
                continue
            total += 1
            partition_key = f"pr:{owner}/{repo}/{pr_number}"
            child_cursor = self._state.get(partition_key, {}).get("synced_at", "")
            if pr_updated_at and child_cursor and pr_updated_at <= child_cursor:
                skipped += 1
                continue
            yield {
                "type": "pr",
                "owner": owner,
                "repo": repo,
                "pr_number": pr_number,
                "pr_database_id": pr_database_id,
                "pr_updated_at": pr_updated_at,
                "partition_key": partition_key,
            }
        if skipped:
            logger.info(f"PR files: {total - skipped}/{total} PRs need file sync ({skipped} skipped, unchanged)")

    def _direct_push_slices(self) -> Iterable[Mapping[str, Any]]:
        """Yield one slice per direct-push commit (default branch, non-merge)."""
        total = 0
        skipped = 0
        # Pass the commits parent's stream state so it can apply its
        # committed_date cursor and skip already-synced branches, instead of
        # re-walking full history every time.
        commits_state = getattr(self._commits_parent, "state", None)
        for commit in self._commits_parent.read_records(sync_mode=None, stream_state=commits_state):
            branch = commit.get("branch_name", "")
            parent_hashes = commit.get("parent_hashes") or []

            # Only default branch, non-merge commits
            # Merge commits have >1 parent — skip those (they're PR merges)
            if len(parent_hashes) > 1:
                continue

            # Filter to default branch only: commit records now carry
            # default_branch_name from the commits stream slice.
            default_branch = commit.get("default_branch_name", "")
            if branch and default_branch and branch != default_branch:
                continue

            owner = commit.get("repo_owner", "")
            repo = commit.get("repo_name", "")
            sha = commit.get("oid", "")
            committed_date = commit.get("committed_date", "")
            if not sha:
                continue
            total += 1
            partition_key = f"commit:{owner}/{repo}/{sha}"
            if self._state.get(partition_key, {}).get("seen"):
                skipped += 1
                continue
            yield {
                "type": "direct_push",
                "owner": owner,
                "repo": repo,
                "sha": sha,
                "committed_date": committed_date,
                "partition_key": partition_key,
            }
        if skipped:
            logger.info(f"Direct-push files: {total - skipped}/{total} commits need file sync ({skipped} skipped, already seen)")

    # --- State management ---

    def _advance_pr_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        pr_updated_at = stream_slice.get("pr_updated_at", "")
        if partition_key and pr_updated_at:
            self._state[partition_key] = {"synced_at": pr_updated_at}

    def _advance_direct_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        if partition_key:
            self._state[partition_key] = {"seen": True}

    # --- Fetch methods (thread-safe) ---

    def _do_rest_get(self, url: str, params: Optional[dict] = None) -> req.Response:
        """REST GET with page-level retry for retriable errors. Thread-safe."""
        def _call():
            self._rate_limiter.throttle("rest")
            resp = req.get(url, headers=rest_headers(self._token), params=params, timeout=30)
            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            if resp.status_code in (502, 503):
                self._rate_limiter.on_secondary_limit()
                raise RuntimeError(f"GitHub secondary rate limit ({resp.status_code}) for {url}")
            if resp.status_code == 429 or resp.status_code >= 500:
                raise RuntimeError(f"GitHub API error {resp.status_code} for {url}")
            return resp
        return retry_request(_call, context=url)

    def _fetch_pr_files(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch all changed files for one PR. Thread-safe."""
        owner = stream_slice.get("owner", "")
        repo = stream_slice.get("repo", "")
        pr_number = stream_slice.get("pr_number")
        pr_database_id = stream_slice.get("pr_database_id")
        pr_updated_at = stream_slice.get("pr_updated_at", "")
        records = []

        url = f"https://api.github.com/repos/{owner}/{repo}/pulls/{pr_number}/files"
        params = {"per_page": "100"}

        while url:
            resp = self._do_rest_get(url, params)
            params = {}

            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{owner}/{repo} PR#{pr_number} files"):
                break

            files = resp.json()
            if not isinstance(files, list):
                files = [files]

            for f in files:
                filename = f.get("filename", "")
                records.append({
                    "pk": _make_pk(self._tenant_id, self._source_id, owner, repo, f"pr{pr_number}", filename),
                    "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, f"pr{pr_number}", filename),
                    "tenant_id": self._tenant_id,
                    "source_id": self._source_id,
                    "data_source": "insight_github",
                    "collected_at": _now_iso(),
                    "source_type": "pr",
                    "pr_number": pr_number,
                    "pr_database_id": pr_database_id,
                    "commit_hash": None,
                    "filename": filename,
                    "status": f.get("status"),
                    "additions": f.get("additions"),
                    "deletions": f.get("deletions"),
                    "changes": f.get("changes"),
                    "previous_filename": f.get("previous_filename"),
                    "patch": f.get("patch"),
                    "sha": f.get("sha"),
                    "blob_url": f.get("blob_url"),
                    "raw_url": f.get("raw_url"),
                    "contents_url": f.get("contents_url"),
                    "pr_updated_at": pr_updated_at,
                    "committed_date": None,
                    "partition_key": stream_slice.get("partition_key"),
                    "repo_owner": owner,
                    "repo_name": repo,
                })

            url = resp.links.get("next", {}).get("url")

        return records

    def _fetch_direct_push_files(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch changed files for one direct-push commit. Thread-safe."""
        owner = stream_slice.get("owner", "")
        repo = stream_slice.get("repo", "")
        sha = stream_slice.get("sha", "")
        committed_date = stream_slice.get("committed_date", "")
        records = []

        url = f"https://api.github.com/repos/{owner}/{repo}/commits/{sha}"
        params = {"per_page": "100"}

        while url:
            resp = self._do_rest_get(url, params)
            params = {}

            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{owner}/{repo}/{sha} files"):
                return records

            data = resp.json()
            files = data.get("files", [])

            for f in files:
                filename = f.get("filename", "")
                records.append({
                    "pk": _make_pk(self._tenant_id, self._source_id, owner, repo, sha, filename),
                    "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, sha, filename),
                    "tenant_id": self._tenant_id,
                    "source_id": self._source_id,
                    "data_source": "insight_github",
                    "collected_at": _now_iso(),
                    "source_type": "direct_push",
                    "pr_number": None,
                    "pr_database_id": None,
                    "commit_hash": sha,
                    "filename": filename,
                    "status": f.get("status"),
                    "additions": f.get("additions"),
                    "deletions": f.get("deletions"),
                    "changes": f.get("changes"),
                    "previous_filename": f.get("previous_filename"),
                    "patch": f.get("patch"),
                    "sha": f.get("sha"),
                    "blob_url": f.get("blob_url"),
                    "raw_url": f.get("raw_url"),
                    "contents_url": f.get("contents_url"),
                    "pr_updated_at": None,
                    "committed_date": committed_date,
                    "partition_key": stream_slice.get("partition_key"),
                    "repo_owner": owner,
                    "repo_name": repo,
                })

            url = resp.links.get("next", {}).get("url")

        return records

    # --- CDK interface ---

    def stream_slices(self, **kwargs):
        # Not used — read_records handles slicing internally
        yield {}

    def next_page_token(self, response, **kwargs):
        return None

    def parse_response(self, response, stream_slice=None, **kwargs):
        return []

    def get_json_schema(self) -> Mapping[str, Any]:
        return {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "pk": {"type": "string"},
                "tenant_id": {"type": "string"},
                "source_id": {"type": "string"},
                "unique_key": {"type": "string"},
                "data_source": {"type": "string"},
                "collected_at": {"type": "string"},
                "source_type": {"type": "string"},
                "pr_number": {"type": ["null", "integer"]},
                "pr_database_id": {"type": ["null", "integer"]},
                "commit_hash": {"type": ["null", "string"]},
                "filename": {"type": ["null", "string"]},
                "status": {"type": ["null", "string"]},
                "additions": {"type": ["null", "integer"]},
                "deletions": {"type": ["null", "integer"]},
                "changes": {"type": ["null", "integer"]},
                "previous_filename": {"type": ["null", "string"]},
                "patch": {"type": ["null", "string"]},
                "sha": {"type": ["null", "string"]},
                "blob_url": {"type": ["null", "string"]},
                "raw_url": {"type": ["null", "string"]},
                "contents_url": {"type": ["null", "string"]},
                "pr_updated_at": {"type": ["null", "string"]},
                "committed_date": {"type": ["null", "string"]},
                "partition_key": {"type": ["null", "string"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

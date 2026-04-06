"""Bitbucket Cloud file changes stream -- PR diffstat + direct-push commit diffstat."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_bitbucket_cloud.clients.auth import rest_headers
from source_bitbucket_cloud.clients.concurrent import fetch_parallel_with_slices, retry_request
from source_bitbucket_cloud.streams.base import BitbucketCloudRestStream, _is_fatal, _make_pk, _now_iso, check_rest_response
from source_bitbucket_cloud.streams.commits import CommitsStream
from source_bitbucket_cloud.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")

API_BASE = "https://api.bitbucket.org/2.0"


class FileChangesStream(BitbucketCloudRestStream):
    """Unified file changes from PRs and direct pushes.

    Two data sources in one table:
    - PR files: GET /repositories/{workspace}/{repo_slug}/pullrequests/{id}/diffstat
    - Direct-push files: GET /repositories/{workspace}/{repo_slug}/diffstat/{commit_hash}

    source_type discriminator: "pr" or "direct_push".
    """

    name = "file_changes"
    cursor_field = "pr_updated_on"

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
            workspace = pr.get("workspace", "")
            repo_slug = pr.get("repo_slug", "")
            pr_id = pr.get("pr_id")
            pr_updated_on = pr.get("updated_on", "")
            if not (workspace and repo_slug and pr_id):
                continue
            total += 1
            partition_key = f"pr:{workspace}/{repo_slug}/{pr_id}"
            child_cursor = self._state.get(partition_key, {}).get("synced_at", "")
            if pr_updated_on and child_cursor and pr_updated_on <= child_cursor:
                skipped += 1
                continue
            yield {
                "type": "pr",
                "workspace": workspace,
                "repo_slug": repo_slug,
                "pr_id": pr_id,
                "pr_updated_on": pr_updated_on,
                "partition_key": partition_key,
            }
        if skipped:
            logger.info(f"PR files: {total - skipped}/{total} PRs need file sync ({skipped} skipped, unchanged)")

    def _direct_push_slices(self) -> Iterable[Mapping[str, Any]]:
        """Yield one slice per direct-push commit (default branch, non-merge)."""
        total = 0
        skipped = 0
        commits_state = getattr(self._commits_parent, "state", None)
        for commit in self._commits_parent.read_records(sync_mode=None, stream_state=commits_state):
            branch = commit.get("branch_name", "")
            parent_hashes = commit.get("parent_hashes") or []

            # Only non-merge commits (merge commits have >1 parent)
            if len(parent_hashes) > 1:
                continue

            # Filter to default branch only
            default_branch = commit.get("default_branch_name", "")
            if branch and default_branch and branch != default_branch:
                continue

            workspace = commit.get("repo_owner", "")
            repo_slug = commit.get("repo_name", "")
            commit_hash = commit.get("commit_hash", "")
            committed_date = commit.get("date", "")
            if not commit_hash:
                continue
            total += 1
            partition_key = f"commit:{workspace}/{repo_slug}/{commit_hash}"
            if self._state.get(partition_key, {}).get("seen"):
                skipped += 1
                continue
            yield {
                "type": "direct_push",
                "workspace": workspace,
                "repo_slug": repo_slug,
                "commit_hash": commit_hash,
                "committed_date": committed_date,
                "partition_key": partition_key,
            }
        if skipped:
            logger.info(f"Direct-push files: {total - skipped}/{total} commits need file sync ({skipped} skipped, already seen)")

    # --- State management ---

    def _advance_pr_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        pr_updated_on = stream_slice.get("pr_updated_on", "")
        if partition_key and pr_updated_on:
            self._state[partition_key] = {"synced_at": pr_updated_on}

    def _advance_direct_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        if partition_key:
            self._state[partition_key] = {"seen": True}

    # --- Fetch methods (thread-safe) ---

    def _do_rest_get(self, url: str, params: Optional[dict] = None) -> req.Response:
        """REST GET with page-level retry for retriable errors. Thread-safe."""
        def _call():
            self._rate_limiter.wait_if_needed("rest")
            resp = req.get(url, headers=rest_headers(self._username, self._token), params=params, timeout=30)
            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            if resp.status_code in (502, 503):
                self._rate_limiter.on_secondary_limit()
                raise RuntimeError(f"Bitbucket Cloud secondary rate limit ({resp.status_code}) for {url}")
            if resp.status_code == 429 or resp.status_code >= 500:
                raise RuntimeError(f"Bitbucket Cloud API error {resp.status_code} for {url}")
            return resp
        return retry_request(_call, context=url)

    def _fetch_pr_files(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch all changed files for one PR via diffstat. Thread-safe."""
        workspace = stream_slice.get("workspace", "")
        repo_slug = stream_slice.get("repo_slug", "")
        pr_id = stream_slice.get("pr_id")
        pr_updated_on = stream_slice.get("pr_updated_on", "")
        records: List[Mapping[str, Any]] = []

        url: Optional[str] = f"{API_BASE}/repositories/{workspace}/{repo_slug}/pullrequests/{pr_id}/diffstat"

        while url:
            resp = self._do_rest_get(url)
            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{workspace}/{repo_slug} PR#{pr_id} diffstat"):
                break

            body = resp.json()
            values = body.get("values", [])

            for entry in values:
                status = entry.get("status", "")
                old_file = entry.get("old") or {}
                new_file = entry.get("new") or {}

                # File path: new.path for added/modified, old.path for deleted
                if status == "removed":
                    filepath = old_file.get("path", "")
                else:
                    filepath = new_file.get("path", "")

                records.append({
                    "pk": _make_pk(self._tenant_id, self._source_instance_id, workspace, repo_slug, f"pr{pr_id}", filepath),
                    "tenant_id": self._tenant_id,
                    "source_instance_id": self._source_instance_id,
                    "data_source": "insight_bitbucket_cloud",
                    "collected_at": _now_iso(),
                    "source_type": "pr",
                    "pr_id": pr_id,
                    "commit_hash": None,
                    "filename": filepath,
                    "status": status,
                    "additions": entry.get("lines_added"),
                    "deletions": entry.get("lines_removed"),
                    "old_path": old_file.get("path"),
                    "new_path": new_file.get("path"),
                    "pr_updated_on": pr_updated_on,
                    "committed_date": None,
                    "partition_key": stream_slice.get("partition_key"),
                    "workspace": workspace,
                    "repo_slug": repo_slug,
                })

            url = body.get("next")

        return records

    def _fetch_direct_push_files(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch changed files for one direct-push commit via diffstat. Thread-safe."""
        workspace = stream_slice.get("workspace", "")
        repo_slug = stream_slice.get("repo_slug", "")
        commit_hash = stream_slice.get("commit_hash", "")
        committed_date = stream_slice.get("committed_date", "")
        records: List[Mapping[str, Any]] = []

        url: Optional[str] = f"{API_BASE}/repositories/{workspace}/{repo_slug}/diffstat/{commit_hash}"

        while url:
            resp = self._do_rest_get(url)
            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{workspace}/{repo_slug}/{commit_hash} diffstat"):
                return records

            body = resp.json()
            values = body.get("values", [])

            for entry in values:
                status = entry.get("status", "")
                old_file = entry.get("old") or {}
                new_file = entry.get("new") or {}

                if status == "removed":
                    filepath = old_file.get("path", "")
                else:
                    filepath = new_file.get("path", "")

                records.append({
                    "pk": _make_pk(self._tenant_id, self._source_instance_id, workspace, repo_slug, commit_hash, filepath),
                    "tenant_id": self._tenant_id,
                    "source_instance_id": self._source_instance_id,
                    "data_source": "insight_bitbucket_cloud",
                    "collected_at": _now_iso(),
                    "source_type": "direct_push",
                    "pr_id": None,
                    "commit_hash": commit_hash,
                    "filename": filepath,
                    "status": status,
                    "additions": entry.get("lines_added"),
                    "deletions": entry.get("lines_removed"),
                    "old_path": old_file.get("path"),
                    "new_path": new_file.get("path"),
                    "pr_updated_on": None,
                    "committed_date": committed_date,
                    "partition_key": stream_slice.get("partition_key"),
                    "workspace": workspace,
                    "repo_slug": repo_slug,
                })

            url = body.get("next")

        return records

    # --- CDK interface ---

    def stream_slices(self, **kwargs):
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
                "source_instance_id": {"type": "string"},
                "data_source": {"type": "string"},
                "collected_at": {"type": "string"},
                "source_type": {"type": "string"},
                "pr_id": {"type": ["null", "integer"]},
                "commit_hash": {"type": ["null", "string"]},
                "filename": {"type": ["null", "string"]},
                "status": {"type": ["null", "string"]},
                "additions": {"type": ["null", "integer"]},
                "deletions": {"type": ["null", "integer"]},
                "old_path": {"type": ["null", "string"]},
                "new_path": {"type": ["null", "string"]},
                "pr_updated_on": {"type": ["null", "string"]},
                "committed_date": {"type": ["null", "string"]},
                "partition_key": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }

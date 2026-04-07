"""Bitbucket Cloud commits stream (REST, incremental, partitioned by repo+branch)."""

import logging
import re
from typing import Any, Iterable, Mapping, MutableMapping, Optional

import requests as req

from source_bitbucket_cloud.clients.auth import rest_headers
from source_bitbucket_cloud.clients.concurrent import retry_request
from source_bitbucket_cloud.streams.base import (
    BitbucketCloudRestStream,
    _is_fatal,
    _make_unique_key,
    _now_iso,
    check_rest_response,
)

logger = logging.getLogger("airbyte")

_AUTHOR_RE = re.compile(r"^(.*?)\s*<([^>]+)>$")

API_BASE = "https://api.bitbucket.org/2.0"


def _parse_author_raw(raw: str | None) -> tuple[str | None, str | None]:
    """Parse ``"Name <email>"`` into (name, email).

    Fallback: if no angle brackets, entire string is the name with email=None.
    """
    if not raw:
        return None, None
    m = _AUTHOR_RE.match(raw.strip())
    if m:
        name = m.group(1).strip() or None
        email = m.group(2).strip() or None
        return name, email
    return raw.strip() or None, None


class CommitsStream(BitbucketCloudRestStream):
    """Fetches commits per branch via REST API, incremental by commit date.

    API: GET /repositories/{workspace}/{repo_slug}/commits/{branch}

    Pagination: newest-to-oldest. Early-exit when ``commit.date <= cursor_date``.
    State: per-partition ``{workspace}/{repo}/{branch}`` with ``date`` cursor
    and ``head_sha`` for skip-unchanged optimisation.
    """

    name = "commits"
    cursor_field = "date"

    def __init__(
        self,
        parent,  # BranchesStream — not imported to avoid circular deps
        start_date: str | None = None,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._parent = parent
        self._start_date = start_date
        self._partitions_with_errors: set = set()

    # ------------------------------------------------------------------
    # Slices
    # ------------------------------------------------------------------

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        repos_skipped_fresh = 0

        # Group branches by repo for freshness gate
        repo_branches: dict[tuple[str, str], list[dict]] = {}
        for record in self._parent.read_records(sync_mode=None):
            workspace = record.get("workspace", "")
            repo_slug = record.get("repo_slug", "")
            if workspace and repo_slug:
                repo_branches.setdefault((workspace, repo_slug), []).append(record)

        for (workspace, repo_slug), branches in repo_branches.items():
            # --- Repo freshness gate ---
            repo_updated_on = ""
            for rec in branches:
                uo = rec.get("repo_updated_on", "")
                if uo:
                    repo_updated_on = uo
                    break

            repo_state_key = f"_repo:{workspace}/{repo_slug}"
            stored_updated_on = state.get(repo_state_key, {}).get("updated_on", "")
            if repo_updated_on and stored_updated_on and repo_updated_on <= stored_updated_on:
                repos_skipped_fresh += 1
                logger.info(
                    f"Commit freshness: skipping {workspace}/{repo_slug} "
                    f"(updated_on unchanged: {repo_updated_on})"
                )
                continue

            # --- Default branch ---
            default_branch = ""
            for rec in branches:
                db = rec.get("default_branch_name", "")
                if db:
                    default_branch = db
                    break

            # --- HEAD SHA unchanged -> skip branch ---
            for rec in branches:
                branch_name = rec.get("name", "")
                head_sha = rec.get("head_sha", "")
                partition_key = f"{workspace}/{repo_slug}/{branch_name}"
                stored = state.get(partition_key, {})
                stored_head = stored.get("head_sha", "")

                if head_sha and stored_head and head_sha == stored_head:
                    logger.debug(
                        f"HEAD unchanged: skipping {workspace}/{repo_slug}/{branch_name} "
                        f"(HEAD {head_sha[:8]})"
                    )
                    continue

                cursor_value = stored.get(self.cursor_field)

                # Force-push detection: if HEAD changed, the timestamp cursor
                # is unreliable (rewritten commits may have older dates).
                # Fall back to start_date so we re-fetch the full branch.
                if stored_head and head_sha and head_sha != stored_head and cursor_value:
                    logger.info(
                        f"HEAD changed on {workspace}/{repo_slug}/{branch_name} "
                        f"({stored_head[:8]}→{head_sha[:8]}): resetting cursor for re-fetch"
                    )
                    cursor_value = None

                yield {
                    "workspace": workspace,
                    "repo_slug": repo_slug,
                    "branch": branch_name,
                    "default_branch": default_branch,
                    "partition_key": partition_key,
                    "cursor_value": cursor_value,
                    "head_sha": head_sha,
                    "repo_updated_on": repo_updated_on,
                }

        if repos_skipped_fresh:
            logger.info(f"Commit freshness: skipped {repos_skipped_fresh} unchanged repos")

    # ------------------------------------------------------------------
    # CDK hooks — we bypass the CDK HTTP machinery and do manual fetching
    # ------------------------------------------------------------------

    def _path(self, **kwargs) -> str:
        # Not used — we drive fetching via read_records / _fetch_commits_for_branch
        return ""

    def read_records(
        self,
        sync_mode=None,
        stream_slice=None,
        stream_state=None,
        **kwargs,
    ) -> Iterable[Mapping[str, Any]]:
        if stream_slice is None:
            for branch_slice in self.stream_slices(stream_state=stream_state):
                yield from self._fetch_commits_for_branch(branch_slice)
        else:
            yield from self._fetch_commits_for_branch(stream_slice)

    # ------------------------------------------------------------------
    # Manual REST fetch with pagination + early-exit
    # ------------------------------------------------------------------

    def _do_rest_get(self, url: str, context: str = "") -> req.Response:
        """Single GET with throttle, rate-limit update, and retry."""

        def _call():
            self._rate_limiter.wait_if_needed("rest")
            resp = req.get(
                url,
                headers=rest_headers(self._email, self._token),
                timeout=30,
            )
            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            self._rate_limiter.wait_if_needed("rest")
            if not check_rest_response(resp, context):
                return resp  # 404/409 — caller checks status
            return resp

        return retry_request(_call, context=context)

    def _fetch_commits_for_branch(
        self,
        stream_slice: Mapping[str, Any],
    ) -> Iterable[Mapping[str, Any]]:
        """Paginate commits newest-to-oldest, early-exit on cursor date."""
        workspace = stream_slice.get("workspace", "")
        repo_slug = stream_slice.get("repo_slug", "")
        branch = stream_slice.get("branch", "")
        default_branch = stream_slice.get("default_branch", "")
        cursor_value = stream_slice.get("cursor_value")
        head_sha = stream_slice.get("head_sha", "")
        repo_updated_on = stream_slice.get("repo_updated_on", "")

        url: str | None = (
            f"{API_BASE}/repositories/{workspace}/{repo_slug}/commits/{branch}"
        )
        context = f"commits {workspace}/{repo_slug}/{branch}"
        page = 0

        while url:
            page += 1
            try:
                resp = self._do_rest_get(url, context=f"{context} page {page}")
            except Exception as exc:
                if _is_fatal(exc):
                    raise
                logger.error(f"Commits fetch error for {context}: {exc}")
                partition_key = f"{workspace}/{repo_slug}/{branch}"
                self._partitions_with_errors.add(partition_key)
                return

            if resp.status_code in (404, 409):
                logger.warning(f"Skipping {context} ({resp.status_code})")
                return

            body = resp.json()
            commits = body.get("values", [])
            if not commits:
                return

            early_exit = False
            for commit in commits:
                commit_date = commit.get("date", "")

                # Early-exit: stop when we reach already-seen data or start_date cutoff
                if cursor_value and commit_date and commit_date <= cursor_value:
                    early_exit = True
                    break
                if self._start_date and commit_date and commit_date[:10] < self._start_date:
                    early_exit = True
                    break

                # --- Parse author ---
                author_raw = (commit.get("author") or {}).get("raw", "")
                author_name, author_email = _parse_author_raw(author_raw)
                author_user = (commit.get("author") or {}).get("user") or {}

                parent_hashes = [
                    p.get("hash", "") for p in (commit.get("parents") or [])
                ]

                pk_parts = [workspace, repo_slug, commit.get("hash", "")]
                record = {
                    "unique_key": _make_unique_key(self._tenant_id, self._source_id, *pk_parts),
                    "commit_hash": commit.get("hash", ""),
                    "message": commit.get("message"),
                    "date": commit_date,
                    "author_name": author_name,
                    "author_email": author_email,
                    "author_login": author_user.get("nickname"),
                    "author_display_name": author_user.get("display_name"),
                    "author_uuid": author_user.get("uuid"),
                    # Bitbucket doesn't distinguish committer — mirror author
                    "committer_name": author_name,
                    "committer_email": author_email,
                    # Bitbucket commit response has no additions/deletions/changed_files
                    "additions": None,
                    "deletions": None,
                    "changed_files": None,
                    "parent_hashes": parent_hashes,
                    "branch_name": branch,
                    "default_branch_name": default_branch,
                    "repo_owner": workspace,
                    "repo_name": repo_slug,
                    "head_sha": head_sha,
                    "repo_updated_on": repo_updated_on,
                }
                yield self._add_envelope(record)

            if early_exit:
                logger.debug(f"Early exit on cursor date for {context}")
                return

            # Next page via ``next`` URL in response body
            url = body.get("next")

    # ------------------------------------------------------------------
    # State
    # ------------------------------------------------------------------

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = (
            f"{latest_record.get('repo_owner', '')}/"
            f"{latest_record.get('repo_name', '')}/"
            f"{latest_record.get('branch_name', '')}"
        )
        if partition_key in self._partitions_with_errors:
            return current_stream_state

        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(
            self.cursor_field, ""
        )
        if record_cursor > current_cursor:
            head_sha = latest_record.get("head_sha", "")
            cursor_entry: dict[str, Any] = {self.cursor_field: record_cursor}
            if head_sha:
                cursor_entry["head_sha"] = head_sha
            current_stream_state[partition_key] = cursor_entry

        # Repo updated_on for freshness gate
        repo_updated_on = latest_record.get("repo_updated_on", "")
        if repo_updated_on:
            workspace = latest_record.get("repo_owner", "")
            repo_slug = latest_record.get("repo_name", "")
            repo_state_key = f"_repo:{workspace}/{repo_slug}"
            current_stream_state[repo_state_key] = {"updated_on": repo_updated_on}

        return current_stream_state

    # ------------------------------------------------------------------
    # Schema
    # ------------------------------------------------------------------

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
                "commit_hash": {"type": "string"},
                "message": {"type": ["null", "string"]},
                "date": {"type": ["null", "string"]},
                "author_name": {"type": ["null", "string"]},
                "author_email": {"type": ["null", "string"]},
                "author_login": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "committer_name": {"type": ["null", "string"]},
                "committer_email": {"type": ["null", "string"]},
                "additions": {"type": ["null", "integer"]},
                "deletions": {"type": ["null", "integer"]},
                "changed_files": {"type": ["null", "integer"]},
                "parent_hashes": {
                    "type": ["null", "array"],
                    "items": {"type": "string"},
                },
                "branch_name": {"type": "string"},
                "default_branch_name": {"type": ["null", "string"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

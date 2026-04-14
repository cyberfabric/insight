"""Bitbucket Cloud commits stream (REST, incremental, partitioned by repo+branch).

Performance optimizations (all in stream_slices, single-threaded):
1. Repo freshness gate: skip repos where updated_on hasn't changed
2. Branch HEAD SHA dedup: skip sibling branches with same HEAD SHA
3. HEAD SHA unchanged: skip branches where HEAD hasn't moved
4. Seen-hash skip: skip non-default branches whose HEAD is in main's history
5. Force-push detection: reset cursor when HEAD changes
"""

import atexit
import logging
import os
import re
import tempfile
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_bitbucket_cloud.streams.base import (
    BitbucketAuthError,
    BitbucketCloudRestStream,
    _make_unique_key,
    _now_iso,
)
from source_bitbucket_cloud.streams.branches import BranchesStream

logger = logging.getLogger("airbyte")

# Regex to parse "Name <email>" from Bitbucket author.raw
_AUTHOR_RAW_RE = re.compile(r"^(.*?)\s*<([^>]+)>\s*$")


class CommitsStream(BitbucketCloudRestStream):
    """Fetches commits via REST API, partitioned by repo+branch.

    Uses cursor-based pagination (opaque `next` URL from Bitbucket).
    """

    name = "commits"
    cursor_field = "date"

    def __init__(
        self,
        parent: BranchesStream,
        start_date: Optional[str] = None,
        page_size: int = 100,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._parent = parent
        self._start_date = start_date
        self._page_size = page_size
        self._partitions_with_errors: set = set()
        self._current_skipped_siblings: list = []
        self._current_stop_at_sha: Optional[str] = None

        self._stop_pagination: bool = False
        self._seen_hashes: dict[str, str] = {}  # sha → "workspace/slug"
        self._deferred_state_updates: dict[str, dict] = {}  # partition_key → state entry
        # Temp file for passing commit metadata to file_changes (near-zero memory).
        self._commit_meta_file = tempfile.NamedTemporaryFile(
            mode="w", prefix="insight_bb_commits_meta_", suffix=".tsv", delete=False,
        )
        self._commit_meta_path = self._commit_meta_file.name
        atexit.register(lambda p=self._commit_meta_path: os.unlink(p) if os.path.exists(p) else None)
        self._commit_meta_count: int = 0
        logger.info(f"Commit metadata temp file: {self._commit_meta_path}")

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        s = stream_slice or {}
        workspace = s.get("workspace", "")
        slug = s.get("slug", "")
        branch = s.get("branch", "")
        if not workspace or not slug or not branch:
            raise ValueError(
                f"CommitsStream._path() called with incomplete slice: "
                f"workspace={workspace}, slug={slug}, branch={branch}"
            )
        return f"repositories/{workspace}/{slug}/commits/{branch}"

    def request_params(self, **kwargs) -> dict:
        return {"pagelen": str(self._page_size)}

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        if stream_slice is None:
            for branch_slice in self.stream_slices(stream_state=stream_state):
                try:
                    yield from super().read_records(
                        sync_mode=sync_mode, stream_slice=branch_slice,
                        stream_state=stream_state, **kwargs,
                    )
                except BitbucketAuthError:
                    raise
                except Exception as exc:
                    pk = (
                        f"{branch_slice.get('workspace', '')}/"
                        f"{branch_slice.get('slug', '')}/"
                        f"{branch_slice.get('branch', '')}"
                    )
                    self._partitions_with_errors.add(pk)
                    logger.error(f"Failed commits slice {pk}, cursor frozen: {exc}")
        else:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice,
                stream_state=stream_state, **kwargs,
            )

    def next_page_token(self, response, **kwargs):
        """Override to stop pagination on dedup exit or previously-seen HEAD."""
        if self._stop_pagination:
            self._stop_pagination = False
            return None

        try:
            data = response.json()
        except ValueError:
            return None

        # Check for stop_at_sha in current page
        if self._current_stop_at_sha:
            values = data.get("values", [])
            for commit in values:
                if commit.get("hash") == self._current_stop_at_sha:
                    logger.debug(f"Early exit: reached known HEAD {self._current_stop_at_sha[:8]}")
                    return None

        next_url = data.get("next")
        if next_url:
            return {"next_url": next_url}
        return None

    # ------------------------------------------------------------------
    # stream_slices: all branch-level optimizations live here
    # ------------------------------------------------------------------

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}

        # Group all branches by repo
        repo_branches: dict[tuple, list] = {}
        for record in self._parent.get_child_records():
            workspace = record.get("workspace", "")
            slug = record.get("repo_slug", "")
            if workspace and slug:
                repo_branches.setdefault((workspace, slug), []).append(record)

        repos_skipped_fresh = 0
        branches_skipped_head = 0

        for (workspace, slug), branches in repo_branches.items():
            # Bound memory: dedup is per-repo (cross-branch), not cross-repo
            self._seen_hashes.clear()

            # --- Optimization 1: Repo freshness gate ---
            repo_updated_on = ""
            for record in branches:
                uo = record.get("updated_on", "")
                if uo:
                    repo_updated_on = uo
                    break

            repo_state_key = f"_repo:{workspace}/{slug}"
            stored_updated_on = state.get(repo_state_key, {}).get("updated_on", "")
            if repo_updated_on and stored_updated_on and repo_updated_on <= stored_updated_on:
                repos_skipped_fresh += 1
                logger.info(f"Repo freshness: skipping {workspace}/{slug} (updated_on unchanged: {repo_updated_on})")
                continue

            # --- Find default branch ---
            default_branch = ""
            for record in branches:
                db = record.get("mainbranch_name", "")
                if db:
                    default_branch = db
                    break

            # --- Optimization 2: Branch HEAD SHA dedup ---
            def _sort_key(r, db=default_branch):
                return 0 if r.get("name") == db else 1

            seen_heads: dict[str, str] = {}
            skipped_map: dict[str, str] = {}
            selected: list = []
            for record in sorted(branches, key=_sort_key):
                branch_name = record.get("name", "")
                head_sha = record.get("target_hash", "")

                if not head_sha:
                    selected.append(record)
                    continue

                if head_sha in seen_heads:
                    skipped_map[branch_name] = seen_heads[head_sha]
                    continue

                seen_heads[head_sha] = branch_name
                selected.append(record)

            if skipped_map:
                logger.info(
                    f"Branch dedup: {workspace}/{slug} - {len(selected)} of {len(branches)} branches "
                    f"selected, {len(skipped_map)} skipped (duplicate HEAD SHAs)"
                )

            # --- Optimization 3: HEAD SHA unchanged -> skip branch ---
            final_selected: list[tuple] = []
            for record in selected:
                branch_name = record.get("name", "")
                head_sha = record.get("target_hash", "")
                partition_key = f"{workspace}/{slug}/{branch_name}"
                stored = state.get(partition_key, {})
                stored_head = stored.get("head_sha", "")

                # HEAD SHA unchanged -> skip entirely
                if head_sha and stored_head and head_sha == stored_head:
                    branches_skipped_head += 1
                    logger.debug(f"HEAD unchanged: skipping {partition_key} (HEAD {head_sha[:8]})")
                    continue

                final_selected.append((record, head_sha, stored_head))

            if branches_skipped_head:
                logger.info(
                    f"Branch optimization: {workspace}/{slug} - {len(final_selected)} branches to fetch, "
                    f"{branches_skipped_head} skipped (HEAD unchanged)"
                )
                branches_skipped_head = 0

            # --- Optimization 4: Seen-hash skip for non-default branches ---
            branches_skipped_seen = 0
            for record, head_sha, stored_head in final_selected:
                branch_name = record.get("name", "")

                # After default branch is processed, _seen_hashes is populated.
                # Skip non-default branches whose HEAD is already in main's history.
                if branch_name != default_branch and head_sha and head_sha in self._seen_hashes:
                    branches_skipped_seen += 1
                    partition_key = f"{workspace}/{slug}/{branch_name}"
                    if head_sha:
                        self._deferred_state_updates[partition_key] = {
                            **state.get(partition_key, {}),
                            "head_sha": head_sha,
                        }
                    continue

                partition_key = f"{workspace}/{slug}/{branch_name}"
                cursor_value = state.get(partition_key, {}).get(self.cursor_field)

                # Optimization 5: Force-push detection
                head_changed = stored_head and head_sha and head_sha != stored_head
                if head_changed and cursor_value:
                    logger.info(
                        f"HEAD changed on {partition_key} "
                        f"({stored_head[:8]}->{head_sha[:8]}): resetting cursor for re-fetch"
                    )
                    cursor_value = None  # falls back to start_date

                yield {
                    "workspace": workspace,
                    "slug": slug,
                    "branch": branch_name,
                    "default_branch": default_branch,
                    "partition_key": partition_key,
                    "cursor_value": cursor_value,
                    "head_sha": head_sha,
                    "stop_at_sha": stored_head,
                    "repo_updated_on": repo_updated_on,
                    "_skipped_siblings": [
                        f"{workspace}/{slug}/{sb}"
                        for sb, chosen in skipped_map.items()
                        if chosen == branch_name
                    ],
                }

            if branches_skipped_seen:
                logger.info(
                    f"Seen-hash skip: {workspace}/{slug} - {branches_skipped_seen} non-default branches "
                    f"skipped (HEAD already in default branch history)"
                )

    # ------------------------------------------------------------------
    # parse_response
    # ------------------------------------------------------------------

    def parse_response(self, response, stream_slice=None, **kwargs):
        self._check_near_limit(response)

        s = stream_slice or {}
        self._current_skipped_siblings = s.get("_skipped_siblings", [])
        self._current_stop_at_sha = s.get("stop_at_sha")
        head_sha = s.get("head_sha", "")
        repo_updated_on = s.get("repo_updated_on", "")
        default_branch = s.get("default_branch", "")

        partition_key = f"{s.get('workspace', '')}/{s.get('slug', '')}/{s.get('branch', '')}"

        if response.status_code == 404:
            logger.warning(f"Skipping commits for {partition_key} (404)")
            return

        data = response.json()
        values = data.get("values", [])
        workspace = s.get("workspace", "")
        slug = s.get("slug", "")
        branch = s.get("branch", "")
        cursor_value = s.get("cursor_value")

        hit_seen = False
        for commit in values:
            commit_hash = commit.get("hash", "")
            commit_date = commit.get("date", "")

            # Early exit: stop at previously-seen HEAD
            if self._current_stop_at_sha and commit_hash == self._current_stop_at_sha:
                logger.debug(f"Early exit: reached known commit {commit_hash[:8]} on {workspace}/{slug}/{branch}")
                self._stop_pagination = True
                return

            # Date-based filtering for incremental sync
            if cursor_value and commit_date and commit_date <= cursor_value:
                self._stop_pagination = True
                return

            # Start date filter for first sync
            if self._start_date and commit_date and commit_date[:10] < self._start_date:
                self._stop_pagination = True
                return

            # Dedup: skip commits already seen from earlier branches
            if commit_hash in self._seen_hashes:
                hit_seen = True
                continue
            self._seen_hashes[commit_hash] = f"{workspace}/{slug}"

            author = commit.get("author") or {}
            author_raw = author.get("raw", "")
            author_user = author.get("user") or {}

            # Parse "Name <email>" from author.raw
            author_name = author_raw
            author_email = None
            match = _AUTHOR_RAW_RE.match(author_raw)
            if match:
                author_name = match.group(1).strip()
                author_email = match.group(2).strip()

            parents = commit.get("parents") or []
            parent_hashes = [p.get("hash", "") for p in parents if p.get("hash")]

            record = {
                "unique_key": _make_unique_key(
                    self._tenant_id, self._source_id, workspace, slug, commit_hash,
                ),
                "tenant_id": self._tenant_id,
                "source_id": self._source_id,
                "data_source": "insight_bitbucket_cloud",
                "collected_at": _now_iso(),
                "hash": commit_hash,
                "message": commit.get("message"),
                "date": commit_date,
                "author_raw": author_raw,
                "author_name": author_name,
                "author_email": author_email,
                "author_display_name": author_user.get("display_name"),
                "author_uuid": author_user.get("uuid"),
                "author_nickname": author_user.get("nickname"),
                "parent_hashes": parent_hashes,
                "workspace": workspace,
                "repo_slug": slug,
                "branch_name": branch,
                "default_branch_name": default_branch,
                "head_sha": head_sha,
                "repo_updated_on": repo_updated_on,
            }
            yield record

            # Write metadata row for file_changes stream (TSV, disk-backed)
            parent_count = len(parent_hashes)
            self._commit_meta_file.write(
                f"{commit_hash}\t{workspace}\t{slug}\t{commit_date}\t{parent_count}\n"
            )
            self._commit_meta_count += 1

        # If we hit any already-seen commit, the rest of this branch is shared
        # history (commits are newest-first). Stop paginating.
        if hit_seen and values:
            logger.debug(f"Dedup exit: hit seen commit on {workspace}/{slug}/{branch}, stopping pagination")
            self._stop_pagination = True
            return

    # ------------------------------------------------------------------
    # get_updated_state: per-partition cursor with head_sha + updated_on
    # ------------------------------------------------------------------

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = (
            f"{latest_record.get('workspace', '')}/"
            f"{latest_record.get('repo_slug', '')}/"
            f"{latest_record.get('branch_name', '')}"
        )
        if partition_key in self._partitions_with_errors:
            return current_stream_state

        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(self.cursor_field, "")
        head_sha = latest_record.get("head_sha", "")
        cursor_entry = dict(current_stream_state.get(partition_key, {}))
        if record_cursor > current_cursor:
            cursor_entry[self.cursor_field] = record_cursor
        if head_sha:
            cursor_entry["head_sha"] = head_sha
        if cursor_entry:
            current_stream_state[partition_key] = cursor_entry

            # Mirror cursor to skipped siblings (same HEAD SHA)
            for sibling_key in self._current_skipped_siblings:
                sibling_cursor = current_stream_state.get(sibling_key, {}).get(self.cursor_field, "")
                if record_cursor > sibling_cursor:
                    current_stream_state[sibling_key] = dict(cursor_entry)

        # Store repo updated_on for freshness gate
        repo_updated_on = latest_record.get("repo_updated_on", "")
        if repo_updated_on:
            workspace = latest_record.get("workspace", "")
            slug = latest_record.get("repo_slug", "")
            repo_state_key = f"_repo:{workspace}/{slug}"
            current_stream_state[repo_state_key] = {"updated_on": repo_updated_on}

        # Apply deferred state updates (from seen-hash skipped branches in stream_slices)
        if self._deferred_state_updates:
            for key, entry in self._deferred_state_updates.items():
                if key not in current_stream_state:
                    current_stream_state[key] = entry
                else:
                    current_stream_state[key] = {**current_stream_state[key], **entry}
            self._deferred_state_updates.clear()

        return current_stream_state

    def get_commit_meta_path(self) -> str:
        """Return path to temp file with commit metadata for file_changes.

        Format: TSV with columns hash, workspace, slug, date, parent_count.
        Must be called after the commits stream has been fully driven by the CDK.
        """
        if not self._commit_meta_file.closed:
            self._commit_meta_file.close()
        logger.info(f"Commit metadata: {self._commit_meta_count} rows written to {self._commit_meta_path}")
        return self._commit_meta_path

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
                "hash": {"type": "string"},
                "message": {"type": ["null", "string"]},
                "date": {"type": ["null", "string"]},
                "author_raw": {"type": ["null", "string"]},
                "author_name": {"type": ["null", "string"]},
                "author_email": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "author_nickname": {"type": ["null", "string"]},
                "parent_hashes": {"type": ["null", "array"], "items": {"type": "string"}},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
                "branch_name": {"type": "string"},
                "default_branch_name": {"type": ["null", "string"]},
            },
        }

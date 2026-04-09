"""GitHub pull requests stream (GraphQL, incremental, child of repos)."""

import atexit
import json
import logging
import os
import tempfile
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_github_v2.queries import BULK_PR_QUERY
from source_github_v2.streams.base import GitHubGraphQLStream, _make_unique_key
from source_github_v2.streams.repositories import RepositoriesStream

logger = logging.getLogger("airbyte")


class PullRequestsStream(GitHubGraphQLStream):
    """Fetches PRs via GraphQL bulk query, incremental by updated_at.

    Reviews, comments, and PR commits are fetched by separate child streams
    that consume get_child_slices() for slice construction.
    """

    name = "pull_requests"
    cursor_field = "updated_at"
    # NOTE: use_cache=True does NOT work for POST requests in the CDK.
    # requests_cache defaults to allowable_methods=('GET', 'HEAD') only.
    # Child streams use embedded data + overflow pagination instead.

    def __init__(
        self,
        parent: RepositoriesStream,
        start_date: Optional[str] = None,
        page_size: int = 25,
        embedded_page_sizes: Optional[dict] = None,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._parent = parent
        self._start_date = start_date
        self._page_size = page_size
        # Build the PR query with configured embedded page sizes
        eps = embedded_page_sizes or {}
        self._pr_query = (
            BULK_PR_QUERY
            .replace("__COMMITS_PAGE_SIZE__", str(eps.get("commits", 10)))
            .replace("__REVIEWS_PAGE_SIZE__", str(eps.get("reviews", 10)))
            .replace("__COMMENTS_PAGE_SIZE__", str(eps.get("comments", 10)))
            .replace("__RT_PAGE_SIZE__", str(eps.get("review_threads", 15)))
            .replace("__RTC_PAGE_SIZE__", str(eps.get("thread_comments", 2)))
        )
        self._partitions_with_errors: set = set()
        self._child_slice_cache: dict[tuple, dict] = {}
        self._current_cursor_value: Optional[str] = None
        # Disk-backed embedded child data — near-zero memory.
        # Each line is JSON: {commits: {...}, reviews: {...}, comments: {...}, review_threads: {...}}
        # Child streams seek to byte offset stored in child_slice_cache.
        self._embedded_data_file = tempfile.NamedTemporaryFile(
            mode="w", prefix="insight_pr_embedded_", suffix=".jsonl", delete=False,
        )
        self._embedded_data_path = self._embedded_data_file.name
        atexit.register(lambda p=self._embedded_data_path: os.unlink(p) if os.path.exists(p) else None)

    def _query(self) -> str:
        return self._pr_query

    # ------------------------------------------------------------------
    # read_records: delegate to slices when called without a slice
    # ------------------------------------------------------------------

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        if stream_slice is None:
            for repo_slice in self.stream_slices(stream_state=stream_state):
                self._current_cursor_value = None  # reset between slices
                yield from super().read_records(
                    sync_mode=sync_mode, stream_slice=repo_slice,
                    stream_state=stream_state, **kwargs,
                )
        else:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice,
                stream_state=stream_state, **kwargs,
            )

    # ------------------------------------------------------------------
    # _variables
    # ------------------------------------------------------------------

    def _variables(self, stream_slice=None, next_page_token=None) -> dict:
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        if not owner or not repo:
            raise ValueError(
                f"PullRequestsStream._variables() called with incomplete slice: "
                f"owner={owner}, repo={repo}"
            )
        variables: dict[str, Any] = {
            "owner": owner,
            "repo": repo,
            "first": self._page_size,
            "orderBy": {"field": "UPDATED_AT", "direction": "DESC"},
        }
        if next_page_token and "after" in next_page_token:
            variables["after"] = next_page_token["after"]
        return variables

    def _extract_nodes(self, data: dict) -> list:
        return self._safe_get(data, "repository", "pullRequests", "nodes") or []

    def _extract_page_info(self, data: dict) -> dict:
        return self._safe_get(data, "repository", "pullRequests", "pageInfo") or {}

    # ------------------------------------------------------------------
    # stream_slices: repo freshness gate + eager pushed_at persist
    # ------------------------------------------------------------------

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        repos_skipped = 0
        repos_total = 0

        for record in self._parent.get_child_records():
            owner = record.get("owner", "")
            repo = record.get("name", "")
            if not (owner and repo):
                continue
            repos_total += 1

            # No pushed_at gate here — PR metadata (labels, reviews, merges,
            # comments) can change without a push. The per-repo updated_at
            # cursor + early exit in next_page_token handles incrementality.

            partition_key = f"{owner}/{repo}"
            cursor_value = state.get(partition_key, {}).get(self.cursor_field)
            yield {
                "owner": owner,
                "repo": repo,
                "partition_key": partition_key,
                "cursor_value": cursor_value,
            }

    # ------------------------------------------------------------------
    # next_page_token: early exit on incremental cursor
    # ------------------------------------------------------------------

    def next_page_token(self, response, **kwargs):
        """Override to implement early exit on incremental cursor."""
        body = response.json()
        data = body.get("data", {})
        page_info = self._extract_page_info(data)

        nodes = self._extract_nodes(data)
        if nodes:
            last_updated = nodes[-1].get("updatedAt", "")
            if last_updated:
                if self._current_cursor_value and last_updated < self._current_cursor_value:
                    return None
                if self._start_date and last_updated[:10] < self._start_date:
                    return None

        if page_info.get("hasNextPage"):
            return {"after": page_info["endCursor"]}
        return None

    # ------------------------------------------------------------------
    # parse_response
    # ------------------------------------------------------------------

    def parse_response(self, response, stream_slice=None, **kwargs):
        body = response.json()
        self._update_graphql_rate_limit(body, response)

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(f"GraphQL query failed: {body['errors']}")
            logger.warning(f"GraphQL partial errors (emitting data, freezing cursor): {body['errors']}")
            s = stream_slice or {}
            partition_key = f"{s.get('owner', '')}/{s.get('repo', '')}"
            self._partitions_with_errors.add(partition_key)

        data = body.get("data", {})
        nodes = self._extract_nodes(data)
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        cursor_value = s.get("cursor_value")
        self._current_cursor_value = cursor_value

        for pr_node in nodes:
            pr_database_id = pr_node.get("databaseId")
            pr_id = str(pr_database_id) if pr_database_id is not None else ""
            pr_number = pr_node.get("number")
            updated_at = pr_node.get("updatedAt", "")

            # Skip records older than cursor for incremental
            if cursor_value and updated_at and updated_at <= cursor_value:
                continue
            # Skip records older than start_date on first sync
            if self._start_date and updated_at and updated_at[:10] < self._start_date:
                continue

            # Write embedded child data to disk (JSONL) — near-zero memory
            commits_conn = pr_node.get("commits") or {}
            reviews_conn = pr_node.get("reviews") or {}
            comments_conn = pr_node.get("comments") or {}
            review_threads_conn = pr_node.get("reviewThreads") or {}
            rt_nodes = review_threads_conn.get("nodes") or []
            embedded_offset = self._embedded_data_file.tell()
            embedded_data = {
                "commits": {
                    "nodes": commits_conn.get("nodes") or [],
                    "has_next_page": (commits_conn.get("pageInfo") or {}).get("hasNextPage", False),
                    "end_cursor": (commits_conn.get("pageInfo") or {}).get("endCursor"),
                },
                "reviews": {
                    "nodes": reviews_conn.get("nodes") or [],
                    "has_next_page": (reviews_conn.get("pageInfo") or {}).get("hasNextPage", False),
                    "end_cursor": (reviews_conn.get("pageInfo") or {}).get("endCursor"),
                },
                "comments": {
                    "nodes": comments_conn.get("nodes") or [],
                    "has_next_page": (comments_conn.get("pageInfo") or {}).get("hasNextPage", False),
                    "end_cursor": (comments_conn.get("pageInfo") or {}).get("endCursor"),
                },
                "review_threads": {
                    "nodes": rt_nodes,
                    "threads_has_next_page": (review_threads_conn.get("pageInfo") or {}).get("hasNextPage", False),
                    "threads_end_cursor": (review_threads_conn.get("pageInfo") or {}).get("endCursor"),
                },
            }
            self._embedded_data_file.write(json.dumps(embedded_data, separators=(",", ":")) + "\n")

            # Normalize state: MERGED / CLOSED / OPEN
            if pr_node.get("merged"):
                pr_state = "MERGED"
            elif pr_node.get("state") == "CLOSED":
                pr_state = "CLOSED"
            else:
                pr_state = "OPEN"

            author = pr_node.get("author") or {}
            merged_by = pr_node.get("mergedBy") or {}

            labels_nodes = (pr_node.get("labels") or {}).get("nodes") or []
            labels = [label.get("name") for label in labels_nodes if label.get("name")]

            milestone = pr_node.get("milestone") or {}
            merge_commit = pr_node.get("mergeCommit") or {}

            # Requested reviewers (users) and teams
            review_requests = (pr_node.get("reviewRequests") or {}).get("nodes") or []
            requested_reviewers: list[str] = []
            requested_teams: list[str] = []
            for rr in review_requests:
                reviewer = rr.get("requestedReviewer") or {}
                if "login" in reviewer:
                    requested_reviewers.append(reviewer["login"])
                elif "slug" in reviewer:
                    requested_teams.append(reviewer["slug"])

            record = {
                "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, pr_id),
                "database_id": pr_database_id,
                "number": pr_number,
                "title": pr_node.get("title"),
                "body": pr_node.get("body"),
                "state": pr_state,
                "is_draft": pr_node.get("isDraft"),
                "review_decision": pr_node.get("reviewDecision"),
                "labels": labels,
                "milestone_title": milestone.get("title"),
                "merge_commit_sha": merge_commit.get("oid"),
                "created_at": pr_node.get("createdAt"),
                "updated_at": updated_at,
                "closed_at": pr_node.get("closedAt"),
                "merged_at": pr_node.get("mergedAt"),
                "head_ref": pr_node.get("headRefName"),
                "base_ref": pr_node.get("baseRefName"),
                "additions": pr_node.get("additions"),
                "deletions": pr_node.get("deletions"),
                "changed_files": pr_node.get("changedFiles"),
                "author_login": author.get("login"),
                "author_id": author.get("databaseId"),
                "author_email": author.get("email"),
                "merged_by_login": merged_by.get("login"),
                "merged_by_id": merged_by.get("databaseId"),
                "commit_count": commits_conn.get("totalCount"),
                "comment_count": comments_conn.get("totalCount"),
                "review_count": reviews_conn.get("totalCount"),
                "requested_reviewers": requested_reviewers,
                "requested_teams": requested_teams,
                "repo_owner": owner,
                "repo_name": repo,
            }
            yield self._add_envelope(record)

            # Build child slice cache incrementally (dict-keyed to dedup on retry)
            cache_key = (owner, repo, pr_number)
            self._child_slice_cache[cache_key] = {
                "number": pr_number,
                "database_id": pr_database_id,
                "updated_at": updated_at,
                "commit_count": commits_conn.get("totalCount"),
                "comment_count": comments_conn.get("totalCount"),
                "review_count": reviews_conn.get("totalCount"),
                "repo_owner": owner,
                "repo_name": repo,
                "embedded_offset": embedded_offset,
                "commits_complete": not embedded_data["commits"]["has_next_page"],
                "commits_end_cursor": embedded_data["commits"]["end_cursor"],
                "reviews_complete": not embedded_data["reviews"]["has_next_page"],
                "reviews_end_cursor": embedded_data["reviews"]["end_cursor"],
                "comments_complete": not embedded_data["comments"]["has_next_page"],
                "comments_end_cursor": embedded_data["comments"]["end_cursor"],
                "review_threads_has_next_page": embedded_data["review_threads"]["threads_has_next_page"],
                "review_threads_end_cursor": embedded_data["review_threads"]["threads_end_cursor"],
            }

    # ------------------------------------------------------------------
    # get_child_slices: minimal PR metadata for child streams
    # ------------------------------------------------------------------

    def read_embedded_data(self, offset: int, field: str) -> dict:
        """Read embedded child data for a PR from the JSONL file at the given byte offset.

        Args:
            offset: byte offset in the JSONL file (from child slice's embedded_offset)
            field: which child data to extract ("commits", "reviews", "comments", "review_threads")

        Returns:
            The embedded data dict for that field, or {} if not found.
        """
        if not self._embedded_data_file.closed:
            self._embedded_data_file.close()
        with open(self._embedded_data_path, "r") as f:
            f.seek(offset)
            line = f.readline()
            if not line:
                return {}
            try:
                data = json.loads(line)
                return data.get(field, {})
            except (json.JSONDecodeError, ValueError):
                return {}

    def get_child_slices(self) -> list:
        """Return minimal PR metadata for child streams to build slices from.

        Populated during parse_response (no re-read). If called before
        parse_response has run, triggers a full read to populate.
        """
        if self._child_slice_cache:
            return list(self._child_slice_cache.values())
        # Fallback: trigger read if not yet populated (e.g., CDK hasn't driven this stream yet)
        list(self.read_records(sync_mode=None))
        logger.info(f"PR child-slice cache: {len(self._child_slice_cache)} PRs")
        return list(self._child_slice_cache.values())

    # ------------------------------------------------------------------
    # get_updated_state: per-repo cursor
    # ------------------------------------------------------------------

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = f"{latest_record.get('repo_owner', '')}/{latest_record.get('repo_name', '')}"
        if partition_key in self._partitions_with_errors:
            return current_stream_state

        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(self.cursor_field, "")
        if record_cursor > current_cursor:
            current_stream_state[partition_key] = {self.cursor_field: record_cursor}

        return current_stream_state

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
                "database_id": {"type": ["null", "integer"]},
                "number": {"type": ["null", "integer"]},
                "title": {"type": ["null", "string"]},
                "body": {"type": ["null", "string"]},
                "state": {"type": ["null", "string"]},
                "is_draft": {"type": ["null", "boolean"]},
                "review_decision": {"type": ["null", "string"]},
                "labels": {"type": ["null", "array"], "items": {"type": "string"}},
                "milestone_title": {"type": ["null", "string"]},
                "merge_commit_sha": {"type": ["null", "string"]},
                "created_at": {"type": ["null", "string"]},
                "updated_at": {"type": ["null", "string"]},
                "closed_at": {"type": ["null", "string"]},
                "merged_at": {"type": ["null", "string"]},
                "head_ref": {"type": ["null", "string"]},
                "base_ref": {"type": ["null", "string"]},
                "additions": {"type": ["null", "integer"]},
                "deletions": {"type": ["null", "integer"]},
                "changed_files": {"type": ["null", "integer"]},
                "author_login": {"type": ["null", "string"]},
                "author_id": {"type": ["null", "integer"]},
                "author_email": {"type": ["null", "string"]},
                "merged_by_login": {"type": ["null", "string"]},
                "merged_by_id": {"type": ["null", "integer"]},
                "commit_count": {"type": ["null", "integer"]},
                "comment_count": {"type": ["null", "integer"]},
                "review_count": {"type": ["null", "integer"]},
                "requested_reviewers": {"type": ["null", "array"], "items": {"type": "string"}},
                "requested_teams": {"type": ["null", "array"], "items": {"type": "string"}},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

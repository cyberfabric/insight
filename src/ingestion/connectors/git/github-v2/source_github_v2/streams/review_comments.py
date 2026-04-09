"""GitHub PR inline review comments stream (GraphQL embedded + overflow).

Review thread comments are embedded in the bulk PR query with configurable
page sizes (default: 20 threads, 20 comments per thread). This covers
the vast majority of PRs with zero additional API calls.

Overflow handling (all GraphQL):
1. >N threads (configurable): paginate via PR_REVIEW_THREADS_QUERY
2. >M comments in a thread (configurable): paginate via PR_THREAD_COMMENTS_QUERY
3. Embedded data missing/corrupt: full fetch via PR_REVIEW_THREADS_QUERY
"""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_github_v2.queries import PR_REVIEW_THREADS_QUERY, PR_THREAD_COMMENTS_QUERY
from source_github_v2.streams.base import (
    GitHubAuthError,
    GitHubGraphQLStream,
    _make_unique_key,
    _now_iso,
)

logger = logging.getLogger("airbyte")


class ReviewCommentsStream(GitHubGraphQLStream):
    """Fetches inline review comments for each PR via embedded GraphQL data.

    Primary path: embedded reviewThreads from parent PR query (zero API calls).
    Overflow path 1: PR_REVIEW_THREADS_QUERY for >100 threads.
    Overflow path 2: PR_THREAD_COMMENTS_QUERY for threads with >100 comments.

    Uses per-PR incremental state keyed by owner/repo/pr_number
    with synced_at = parent PR updated_at.
    """

    name = "pull_request_review_comments"
    cursor_field = "pull_request_updated_at"

    def __init__(self, parent, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._deferred_state_updates: dict[str, str] = {}  # partition_key → pr_updated_at
        self._partitions_with_errors: set = set()

    def _query(self) -> str:
        return PR_REVIEW_THREADS_QUERY

    def _variables(self, stream_slice=None, next_page_token=None) -> dict:
        s = stream_slice or {}
        variables: dict = {
            "owner": s.get("owner", ""),
            "repo": s.get("repo", ""),
            "prNumber": s.get("pr_number"),
            "first": 100,
        }
        if next_page_token and "after" in next_page_token:
            variables["after"] = next_page_token["after"]
        elif s.get("_overflow_after"):
            variables["after"] = s["_overflow_after"]
        return variables

    def _extract_nodes(self, data: dict) -> list:
        return self._safe_get(data, "repository", "pullRequest", "reviewThreads", "nodes") or []

    def _extract_page_info(self, data: dict) -> dict:
        return self._safe_get(data, "repository", "pullRequest", "reviewThreads", "pageInfo") or {}

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        total = 0
        skipped = 0
        skipped_no_reviews = 0
        for pr in self._parent.get_child_slices():
            owner = pr.get("repo_owner", "")
            repo = pr.get("repo_name", "")
            pr_number = pr.get("number")
            pr_database_id = pr.get("database_id")
            pr_updated_at = pr.get("updated_at", "")
            review_count = pr.get("review_count")
            if not (owner and repo and pr_number):
                continue
            total += 1
            if review_count == 0:
                skipped_no_reviews += 1
                continue
            partition_key = f"{owner}/{repo}/{pr_number}"
            child_cursor = state.get(partition_key, {}).get("synced_at", "")
            if pr_updated_at and child_cursor and pr_updated_at <= child_cursor:
                skipped += 1
                continue
            yield {
                "owner": owner,
                "repo": repo,
                "pr_number": pr_number,
                "pr_database_id": pr_database_id,
                "pr_updated_at": pr_updated_at,
                "partition_key": partition_key,
                "embedded_offset": pr.get("embedded_offset", 0),
                "review_threads_has_next_page": pr.get("review_threads_has_next_page", False),
                "review_threads_end_cursor": pr.get("review_threads_end_cursor"),
            }
        fetched = total - skipped - skipped_no_reviews
        if skipped or skipped_no_reviews:
            logger.info(
                f"Review comments: {fetched}/{total} PRs need sync "
                f"({skipped} unchanged, {skipped_no_reviews} zero reviews)"
            )

    def _make_record(self, comment_node: dict, thread_node: dict, stream_slice: dict) -> dict:
        """Build output record from a GraphQL review thread comment node."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")
        pr_database_id = s.get("pr_database_id")
        pr_id = str(pr_database_id) if pr_database_id is not None else ""

        database_id = comment_node.get("databaseId")
        comment_id = str(database_id) if database_id is not None else ""
        author = comment_node.get("author") or {}

        return {
            "unique_key": _make_unique_key(
                self._tenant_id, self._source_id, owner, repo, pr_id, "rc", comment_id,
            ),
            "tenant_id": self._tenant_id,
            "source_id": self._source_id,
            "data_source": "insight_github",
            "collected_at": _now_iso(),
            "database_id": database_id,
            "pr_number": pr_number,
            "pull_request_id": pr_database_id,
            "body": comment_node.get("body"),
            "filename": comment_node.get("path"),
            "line": comment_node.get("line"),
            "start_line": comment_node.get("startLine"),
            "diff_hunk": comment_node.get("diffHunk"),
            "commit_id": (comment_node.get("commit") or {}).get("oid"),
            "original_commit_id": (comment_node.get("originalCommit") or {}).get("oid"),
            "in_reply_to_id": (comment_node.get("replyTo") or {}).get("databaseId"),
            "thread_resolved": thread_node.get("isResolved"),
            "created_at": comment_node.get("createdAt"),
            "updated_at": comment_node.get("updatedAt"),
            "author_login": author.get("login"),
            "author_id": author.get("databaseId"),
            "author_association": comment_node.get("authorAssociation"),
            "pull_request_updated_at": s.get("pr_updated_at"),
            "repo_owner": owner,
            "repo_name": repo,
        }

    def _yield_thread_comments(self, thread: dict, stream_slice: dict):
        """Yield all comments from a thread, paginating if >100 comments."""
        comments_conn = thread.get("comments") or {}
        comment_nodes = comments_conn.get("nodes") or []
        page_info = comments_conn.get("pageInfo") or {}

        # Yield embedded comments
        for node in comment_nodes:
            yield self._make_record(node, thread, stream_slice)

        # Overflow: paginate this thread's comments if >100
        if not page_info.get("hasNextPage"):
            return

        thread_id = thread.get("id")
        if not thread_id:
            return

        logger.debug(
            f"Review thread {thread_id[:20]}... has >100 comments, "
            f"paginating from {page_info.get('endCursor')}"
        )
        after = page_info.get("endCursor")

        while after:
            body = self._send_graphql(
                PR_THREAD_COMMENTS_QUERY,
                {"threadId": thread_id, "first": 100, "after": after},
            )

            if "errors" in body:
                pk = (stream_slice or {}).get("partition_key", "")
                if pk:
                    logger.warning(f"GraphQL partial errors in thread overflow (freezing cursor): {body['errors']}")
                    self._partitions_with_errors.add(pk)

            payload = body.get("data", {}) or {}
            node_data = payload.get("node") or {}
            thread_info = {"isResolved": node_data.get("isResolved", thread.get("isResolved"))}
            overflow_comments = self._safe_get(node_data, "comments", "nodes") or []
            overflow_page = self._safe_get(node_data, "comments", "pageInfo") or {}

            for node in overflow_comments:
                yield self._make_record(node, thread_info, stream_slice)

            if overflow_page.get("hasNextPage"):
                after = overflow_page.get("endCursor")
            else:
                after = None

    def parse_response(self, response, stream_slice=None, **kwargs):
        """CDK calls this for thread overflow pages. Each thread's comments are yielded inline."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")

        body = response.json()
        self._update_graphql_rate_limit(body, response)

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(
                    f"GraphQL errors for {owner}/{repo} PR#{pr_number} review threads: {body['errors']}"
                )
            logger.warning(f"GraphQL partial errors (emitting data, freezing cursor): {body['errors']}")
            partition_key = s.get("partition_key", f"{owner}/{repo}/{pr_number}")
            self._partitions_with_errors.add(partition_key)

        data = body.get("data", {})
        thread_nodes = self._extract_nodes(data)

        for thread in thread_nodes:
            yield from self._yield_thread_comments(thread, s)

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        """Yield embedded review thread comments, then overflow-paginate if needed."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")

        try:
            # Step 1: read embedded review threads from disk
            rt_data = self._parent.read_embedded_data(s.get("embedded_offset", 0), "review_threads")
            thread_nodes = rt_data.get("nodes") or []
            embedded_count = 0

            for thread in thread_nodes:
                for record in self._yield_thread_comments(thread, s):
                    embedded_count += 1
                    yield record

            # Step 2: if embedded data was read successfully (even if zero comments), check completeness
            embedded_data_available = bool(rt_data)  # non-empty dict means file read succeeded
            if embedded_data_available and not s.get("review_threads_has_next_page", False):
                logger.debug(
                    f"Review comments {owner}/{repo} PR#{pr_number}: "
                    f"{embedded_count} from {len(thread_nodes)} threads (complete)"
                )
                # Mark slice as synced even if zero comments were emitted, so we
                # don't re-fetch PRs that have reviews but no inline comments.
                pk = s.get("partition_key", "")
                pr_updated_at = s.get("pr_updated_at", "")
                if pk and pr_updated_at:
                    self._deferred_state_updates[pk] = pr_updated_at
                return

            # Step 3: overflow or full fetch if embedded data was missing/incomplete
            if not embedded_data_available:
                logger.debug(
                    f"Review comments {owner}/{repo} PR#{pr_number}: "
                    f"no embedded data, full fetch"
                )
            else:
                logger.debug(
                    f"Review comments {owner}/{repo} PR#{pr_number}: "
                    f"{embedded_count} embedded, thread overflow needed"
                )
            end_cursor = s.get("review_threads_end_cursor") if embedded_data_available else None
            if end_cursor:
                overflow_slice = dict(s)
                overflow_slice["_overflow_after"] = end_cursor
                yield from super().read_records(
                    sync_mode=sync_mode, stream_slice=overflow_slice,
                    stream_state=stream_state, **kwargs,
                )
            else:
                yield from super().read_records(
                    sync_mode=sync_mode, stream_slice=stream_slice,
                    stream_state=stream_state, **kwargs,
                )

        except GitHubAuthError:
            raise
        except Exception as exc:
            pk = s.get("partition_key", "?")
            logger.error(f"Failed review_comments slice {pk}: {exc}")
            raise

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        owner = latest_record.get("repo_owner", "")
        repo = latest_record.get("repo_name", "")
        pr_number = latest_record.get("pr_number")
        partition_key = f"{owner}/{repo}/{pr_number}" if (owner and repo and pr_number) else ""
        if partition_key in self._partitions_with_errors:
            return current_stream_state
        pr_updated_at = latest_record.get("pull_request_updated_at", "")
        if partition_key and pr_updated_at:
            current_stream_state[partition_key] = {"synced_at": pr_updated_at}
        # Apply deferred state for slices that emitted zero records
        if self._deferred_state_updates:
            for key, updated_at in self._deferred_state_updates.items():
                if key not in current_stream_state:
                    current_stream_state[key] = {"synced_at": updated_at}
            self._deferred_state_updates.clear()
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
                "pr_number": {"type": ["null", "integer"]},
                "pull_request_id": {"type": ["null", "integer"]},
                "body": {"type": ["null", "string"]},
                "filename": {"type": ["null", "string"]},
                "line": {"type": ["null", "integer"]},
                "start_line": {"type": ["null", "integer"]},
                "diff_hunk": {"type": ["null", "string"]},
                "commit_id": {"type": ["null", "string"]},
                "original_commit_id": {"type": ["null", "string"]},
                "in_reply_to_id": {"type": ["null", "integer"]},
                "thread_resolved": {"type": ["null", "boolean"]},
                "created_at": {"type": ["null", "string"]},
                "updated_at": {"type": ["null", "string"]},
                "author_login": {"type": ["null", "string"]},
                "author_id": {"type": ["null", "integer"]},
                "author_association": {"type": ["null", "string"]},
                "pull_request_updated_at": {"type": ["null", "string"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

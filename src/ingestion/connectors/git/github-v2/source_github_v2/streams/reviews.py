"""GitHub PR reviews stream (GraphQL, per-PR sequential, incremental).

Follows the same pattern as PRCommitsStream and CommentsStream:
- Embedded reviews from the parent PR query are yielded first
- If the PR has <= 100 reviews (reviews_complete=True), no additional
  API call is needed
- Otherwise, pagination continues from the embedded end_cursor
"""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from source_github_v2.queries import PR_REVIEWS_QUERY
from source_github_v2.streams.base import (
    GitHubAuthError,
    GitHubGraphQLStream,
    _make_unique_key,
    _now_iso,
)

logger = logging.getLogger("airbyte")


class ReviewsStream(GitHubGraphQLStream):
    """Fetches reviews for each PR via GraphQL.

    Uses per-PR incremental state keyed by owner/repo/pr_number
    with synced_at = parent PR updated_at.
    """

    name = "pull_request_reviews"
    cursor_field = "pull_request_updated_at"

    def __init__(self, parent, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._partitions_with_errors: set = set()

    def _query(self) -> str:
        return PR_REVIEWS_QUERY

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
                "reviews_complete": pr.get("reviews_complete", False),
                "reviews_end_cursor": pr.get("reviews_end_cursor"),
            }
        fetched = total - skipped - skipped_no_reviews
        if skipped or skipped_no_reviews:
            logger.info(
                f"Reviews: {fetched}/{total} PRs need review sync "
                f"({skipped} unchanged, {skipped_no_reviews} zero reviews)"
            )

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
        return self._safe_get(data, "repository", "pullRequest", "reviews", "nodes") or []

    def _extract_page_info(self, data: dict) -> dict:
        return self._safe_get(data, "repository", "pullRequest", "reviews", "pageInfo") or {}

    def _make_record(self, node: dict, stream_slice: dict) -> Optional[dict]:
        """Build an output record from a GraphQL review node. Returns None for PENDING reviews."""
        state_val = node.get("state")
        if state_val == "PENDING":
            return None

        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")
        pr_database_id = s.get("pr_database_id")
        pr_id = str(pr_database_id) if pr_database_id is not None else ""

        database_id = node.get("databaseId")
        review_id = str(database_id) if database_id is not None else ""
        author = node.get("author") or {}

        return {
            "unique_key": _make_unique_key(
                self._tenant_id, self._source_id, owner, repo, pr_id, review_id,
            ),
            "tenant_id": self._tenant_id,
            "source_id": self._source_id,
            "data_source": "insight_github",
            "collected_at": _now_iso(),
            "database_id": database_id,
            "pr_number": pr_number,
            "pull_request_id": pr_database_id,
            "state": state_val,
            "body": node.get("body"),
            "submitted_at": node.get("submittedAt"),
            "author_login": author.get("login"),
            "author_id": author.get("databaseId"),
            "author_association": node.get("authorAssociation"),
            "commit_id": (node.get("commit") or {}).get("oid"),
            "pull_request_updated_at": s.get("pr_updated_at"),
            "repo_owner": owner,
            "repo_name": repo,
        }

    def parse_response(self, response, stream_slice=None, **kwargs):
        """CDK calls this for each overflow page."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")

        body = response.json()
        self._update_graphql_rate_limit(body, response)

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(
                    f"GraphQL errors for {owner}/{repo} PR#{pr_number} reviews: {body['errors']}"
                )
            logger.warning(f"GraphQL partial errors (emitting data, freezing cursor): {body['errors']}")
            partition_key = s.get("partition_key", f"{owner}/{repo}/{pr_number}")
            self._partitions_with_errors.add(partition_key)

        data = body.get("data", {})
        nodes = self._extract_nodes(data)

        for node in nodes:
            record = self._make_record(node, s)
            if record is not None:
                yield record

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        """Yield embedded records first, then overflow-paginate if needed."""
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        pr_number = s.get("pr_number")

        try:
            # Step 1: read embedded records from disk
            reviews_data = self._parent.read_embedded_data(s.get("embedded_offset", 0), "reviews")
            embedded_nodes = reviews_data.get("nodes") or []
            embedded_count = 0
            for node in embedded_nodes:
                record = self._make_record(node, s)
                if record is not None:
                    embedded_count += 1
                    yield record

            # Step 2: if embedded data was read successfully, check completeness
            embedded_data_available = bool(reviews_data)
            if embedded_data_available and s.get("reviews_complete", False):
                logger.debug(f"Reviews {owner}/{repo} PR#{pr_number}: {embedded_count} embedded (complete)")
                return

            # Step 3: overflow or full fetch if embedded data was missing/incomplete
            if not embedded_data_available:
                logger.debug(f"Reviews {owner}/{repo} PR#{pr_number}: no embedded data, full fetch")
            else:
                logger.debug(f"Reviews {owner}/{repo} PR#{pr_number}: {embedded_count} embedded, overflow needed")
            end_cursor = s.get("reviews_end_cursor") if embedded_data_available else None
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
            logger.error(f"Failed reviews slice {pk}: {exc}")
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
                "state": {"type": ["null", "string"]},
                "body": {"type": ["null", "string"]},
                "submitted_at": {"type": ["null", "string"]},
                "author_login": {"type": ["null", "string"]},
                "author_id": {"type": ["null", "integer"]},
                "author_association": {"type": ["null", "string"]},
                "commit_id": {"type": ["null", "string"]},
                "pull_request_updated_at": {"type": ["null", "string"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }

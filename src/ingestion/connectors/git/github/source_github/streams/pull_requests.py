"""GitHub pull requests stream (GraphQL, incremental)."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

from source_github.graphql.queries import BULK_PR_QUERY
from source_github.streams.base import GitHubGraphQLStream, _make_pk
from source_github.streams.repositories import RepositoriesStream

logger = logging.getLogger("airbyte")


class PullRequestsStream(GitHubGraphQLStream):
    """Fetches PRs via GraphQL bulk query.

    Reviews and comments are fetched separately by ReviewsStream and
    CommentsStream with proper pagination per PR.
    """

    name = "pull_requests"
    cursor_field = "updated_at"
    use_cache = True  # Reviews/comments streams use this as parent

    def __init__(
        self,
        parent: RepositoriesStream,
        page_size: int = 50,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._parent = parent
        self._page_size = page_size
        self._partitions_with_errors: set = set()

    def _query(self) -> str:
        return BULK_PR_QUERY

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs):
        if stream_slice is None:
            # Called by child stream without a slice — iterate all repo slices
            for repo_slice in self.stream_slices(stream_state=stream_state):
                yield from super().read_records(
                    sync_mode=sync_mode, stream_slice=repo_slice, stream_state=stream_state, **kwargs
                )
        else:
            yield from super().read_records(
                sync_mode=sync_mode, stream_slice=stream_slice, stream_state=stream_state, **kwargs
            )

    def _variables(self, stream_slice=None, next_page_token=None) -> dict:
        s = stream_slice or {}
        owner = s.get("owner", "")
        repo = s.get("repo", "")
        if not owner or not repo:
            raise ValueError(f"PullRequestsStream._variables() called with incomplete slice: owner={owner}, repo={repo}")
        variables = {
            "owner": owner,
            "repo": repo,
            "first": self._page_size,
            "orderBy": {"field": "UPDATED_AT", "direction": "DESC"},
        }
        if next_page_token and "after" in next_page_token:
            variables["after"] = next_page_token["after"]
        return variables

    def _extract_nodes(self, data: dict) -> list:
        try:
            return (
                data.get("repository", {})
                .get("pullRequests", {})
                .get("nodes", [])
            )
        except (AttributeError, TypeError):
            return []

    def _extract_page_info(self, data: dict) -> dict:
        try:
            return (
                data.get("repository", {})
                .get("pullRequests", {})
                .get("pageInfo", {})
            )
        except (AttributeError, TypeError):
            return {}

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        for record in self._parent.read_records(sync_mode=None):
            owner = record.get("owner", {}).get("login", "")
            repo = record.get("name", "")
            if owner and repo:
                partition_key = f"{owner}/{repo}"
                cursor_value = state.get(partition_key, {}).get(self.cursor_field)
                yield {
                    "owner": owner,
                    "repo": repo,
                    "partition_key": partition_key,
                    "cursor_value": cursor_value,
                }

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = f"{latest_record.get('_owner', '')}/{latest_record.get('_repo', '')}"
        if partition_key in self._partitions_with_errors:
            return current_stream_state
        record_cursor = latest_record.get(self.cursor_field, "")
        current_cursor = current_stream_state.get(partition_key, {}).get(self.cursor_field, "")
        if record_cursor > current_cursor:
            current_stream_state[partition_key] = {self.cursor_field: record_cursor}
        return current_stream_state

    def next_page_token(self, response, **kwargs):
        """Override to implement early exit on incremental cursor."""
        body = response.json()
        data = body.get("data", {})
        page_info = self._extract_page_info(data)

        # Early exit: if last node on this page is older than cursor
        nodes = self._extract_nodes(data)
        if nodes and hasattr(self, "_current_cursor_value") and self._current_cursor_value:
            last_updated = nodes[-1].get("updatedAt", "")
            if last_updated and last_updated < self._current_cursor_value:
                return None

        if page_info.get("hasNextPage"):
            return {"after": page_info["endCursor"]}
        return None

    def parse_response(self, response, stream_slice=None, **kwargs):
        body = response.json()
        self._update_graphql_rate_limit(body)
        self._rate_limiter.wait_if_needed("graphql")

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

            # Normalize state
            if pr_node.get("merged"):
                state = "MERGED"
            elif pr_node.get("state") == "CLOSED":
                state = "CLOSED"
            else:
                state = "OPEN"

            author = pr_node.get("author") or {}
            merged_by = pr_node.get("mergedBy") or {}

            labels_nodes = (pr_node.get("labels") or {}).get("nodes") or []
            labels = [l.get("name") for l in labels_nodes if l.get("name")]

            milestone = pr_node.get("milestone") or {}

            merge_commit = pr_node.get("mergeCommit") or {}

            # Extract requested reviewers (users) and teams
            review_requests = (pr_node.get("reviewRequests") or {}).get("nodes") or []
            requested_reviewers = []
            requested_teams = []
            for rr in review_requests:
                reviewer = rr.get("requestedReviewer") or {}
                if "login" in reviewer:
                    requested_reviewers.append(reviewer["login"])
                elif "slug" in reviewer:
                    requested_teams.append(reviewer["slug"])

            record = {
                "pk": _make_pk(self._tenant_id, self._source_instance_id, owner, repo, pr_id),
                "database_id": pr_database_id,
                "number": pr_number,
                "title": pr_node.get("title"),
                "body": pr_node.get("body"),
                "state": state,
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
                "author_database_id": author.get("databaseId"),
                "author_email": author.get("email"),
                "merged_by_login": merged_by.get("login"),
                "merged_by_database_id": merged_by.get("databaseId"),
                "commit_count": (pr_node.get("commits") or {}).get("totalCount"),
                "comment_count": (pr_node.get("comments") or {}).get("totalCount"),
                "review_count": (pr_node.get("reviews") or {}).get("totalCount"),
                "requested_reviewers": requested_reviewers,
                "requested_teams": requested_teams,
                "_owner": owner,
                "_repo": repo,
            }
            yield self._add_envelope(record)

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
                "author_database_id": {"type": ["null", "integer"]},
                "author_email": {"type": ["null", "string"]},
                "merged_by_login": {"type": ["null", "string"]},
                "merged_by_database_id": {"type": ["null", "integer"]},
                "commit_count": {"type": ["null", "integer"]},
                "comment_count": {"type": ["null", "integer"]},
                "review_count": {"type": ["null", "integer"]},
                "requested_reviewers": {"type": ["null", "array"], "items": {"type": "string"}},
                "requested_teams": {"type": ["null", "array"], "items": {"type": "string"}},
                "_owner": {"type": "string"},
                "_repo": {"type": "string"},
            },
        }

"""GitHub Airbyte source connector v2 (CDK-native, ConcurrentSource-ready).

For now this is a standard ``AbstractSource`` that returns ``HttpStream``
instances.  ``ConcurrentSource`` + ``StreamFacade`` wrapping will be added
once all streams work correctly in sequential mode.
"""

import json
import logging
import sys
from pathlib import Path
from typing import Any, List, Mapping, Optional, Tuple

import requests
from airbyte_cdk.sources import AbstractSource
from airbyte_cdk.sources.streams import Stream

from source_github_v2.auth import rest_headers

logger = logging.getLogger("airbyte")


class SourceGitHubV2(AbstractSource):
    """Entry-point for the GitHub v2 Airbyte source connector."""

    def spec(self, logger: Any) -> Mapping[str, Any]:
        from airbyte_cdk.models import ConnectorSpecification

        spec_path = Path(__file__).parent / "spec.json"
        return ConnectorSpecification(**json.loads(spec_path.read_text()))

    def check_connection(
        self, logger: Any, config: Mapping[str, Any]
    ) -> Tuple[bool, Optional[Any]]:
        """Validate auth token and access to each configured organization."""
        token = config["github_token"]
        organizations = config.get("github_organizations", [])
        headers = rest_headers(token)

        try:
            # Validate the token itself
            resp = requests.get(
                "https://api.github.com/rate_limit",
                headers=headers,
                timeout=10,
            )
            if resp.status_code != 200:
                return False, (
                    f"Token validation failed ({resp.status_code}): "
                    f"{resp.text[:200]}"
                )

            # Verify access to each organization
            for org in organizations:
                resp = requests.get(
                    f"https://api.github.com/orgs/{org}/repos?per_page=1",
                    headers=headers,
                    timeout=10,
                )
                if resp.status_code == 404:
                    return False, (
                        f"Organization '{org}' not found or not accessible "
                        f"with this token"
                    )
                if resp.status_code == 403:
                    return False, (
                        f"Token lacks permission to access organization '{org}'"
                    )
                if resp.status_code != 200:
                    return False, (
                        f"Failed to access org '{org}' ({resp.status_code}): "
                        f"{resp.text[:200]}"
                    )

            return True, None
        except requests.RequestException as exc:
            return False, f"GitHub API request failed: {exc}"

    def streams(self, config: Mapping[str, Any]) -> List[Stream]:
        """Build the stream dependency graph.

        Stream hierarchy::

            repos
            +-- branches
            |   +-- commits
            |       +-- file_changes
            +-- prs
                +-- reviews
                +-- comments
                +-- pr_commits
        """
        token = config["github_token"]
        tenant_id = config["insight_tenant_id"]
        source_id = config["insight_source_id"]
        organizations = config["github_organizations"]
        start_date = config.get("github_start_date")
        skip_archived = config.get("github_skip_archived", True)
        skip_forks = config.get("github_skip_forks", True)
        pr_page_size = config.get("github_pr_page_size", 25)
        embedded_page_sizes = {
            "commits": config.get("github_embedded_commits_per_pr", 10),
            "reviews": config.get("github_embedded_reviews_per_pr", 10),
            "comments": config.get("github_embedded_comments_per_pr", 10),
            "review_threads": config.get("github_embedded_review_threads_per_pr", 15),
            "thread_comments": config.get("github_embedded_thread_comments", 2),
        }

        shared = {
            "token": token,
            "tenant_id": tenant_id,
            "source_id": source_id,
        }

        # -- Lazy imports to avoid circular dependencies at module level ----
        from source_github_v2.streams.repositories import RepositoriesStream
        from source_github_v2.streams.branches import BranchesStream
        from source_github_v2.streams.commits import CommitsStream
        from source_github_v2.streams.pull_requests import PullRequestsStream
        from source_github_v2.streams.reviews import ReviewsStream
        from source_github_v2.streams.comments import CommentsStream
        from source_github_v2.streams.pr_commits import PRCommitsStream
        from source_github_v2.streams.file_changes import FileChangesStream
        from source_github_v2.streams.review_comments import ReviewCommentsStream

        repos = RepositoriesStream(
            organizations=organizations,
            skip_archived=skip_archived,
            skip_forks=skip_forks,
            **shared,
        )
        branches = BranchesStream(parent=repos, **shared)
        commits = CommitsStream(parent=branches, start_date=start_date, **shared)
        prs = PullRequestsStream(
            parent=repos, start_date=start_date, page_size=pr_page_size,
            embedded_page_sizes=embedded_page_sizes,
            **shared,
        )
        reviews = ReviewsStream(parent=prs, **shared)
        comments = CommentsStream(parent=prs, **shared)
        pr_commits = PRCommitsStream(parent=prs, **shared)
        review_comments = ReviewCommentsStream(parent=prs, **shared)
        file_changes = FileChangesStream(
            parent=commits,
            **shared,
        )

        return [
            repos,
            branches,
            prs,
            reviews,
            comments,
            review_comments,
            pr_commits,
            commits,        # slow — GraphQL pagination across all branches
            file_changes,   # slowest — one REST call per commit
        ]


def main() -> None:
    """CLI entry-point (``source-github-insight-v2``)."""
    source = SourceGitHubV2()
    from airbyte_cdk.entrypoint import launch

    launch(source, sys.argv[1:])


if __name__ == "__main__":
    main()

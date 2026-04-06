"""GitHub Airbyte source connector (Python CDK)."""

import json
import logging
import sys
from pathlib import Path
from typing import Any, List, Mapping, Optional, Tuple

from airbyte_cdk.models import AirbyteConnectionStatus, Status
from airbyte_cdk.sources import AbstractSource
from airbyte_cdk.sources.streams import Stream

from source_github.clients.rate_limiter import RateLimiter
from source_github.streams.branches import BranchesStream
from source_github.streams.comments import CommentsStream
from source_github.streams.commits import CommitsStream
from source_github.streams.file_changes import FileChangesStream
from source_github.streams.pr_commits import PRCommitsStream
from source_github.streams.pull_requests import PullRequestsStream
from source_github.streams.repositories import RepositoriesStream
from source_github.streams.reviews import ReviewsStream

logger = logging.getLogger("airbyte")


class SourceGitHub(AbstractSource):

    def spec(self, logger) -> Mapping[str, Any]:
        from airbyte_cdk.models import ConnectorSpecification
        spec_path = Path(__file__).parent / "spec.json"
        return ConnectorSpecification(**json.loads(spec_path.read_text()))

    def check_connection(self, logger, config) -> Tuple[bool, Optional[Any]]:
        """Validate auth and org access."""
        import requests
        from source_github.clients.auth import rest_headers

        token = config["token"]
        organizations = config.get("organizations", [])
        headers = rest_headers(token)

        try:
            # Check token validity
            resp = requests.get("https://api.github.com/rate_limit", headers=headers, timeout=10)
            if resp.status_code != 200:
                return False, f"Token validation failed ({resp.status_code}): {resp.text[:200]}"

            # Check access to each configured org
            for org in organizations:
                resp = requests.get(f"https://api.github.com/orgs/{org}/repos?per_page=1", headers=headers, timeout=10)
                if resp.status_code == 404:
                    return False, f"Organization '{org}' not found or not accessible with this token"
                if resp.status_code == 403:
                    return False, f"Token lacks permission to access organization '{org}'"
                if resp.status_code != 200:
                    return False, f"Failed to access org '{org}' ({resp.status_code}): {resp.text[:200]}"

            return True, None
        except Exception as e:
            return False, str(e)

    def streams(self, config: Mapping[str, Any]) -> List[Stream]:
        token = config["token"]
        tenant_id = config["insight_tenant_id"]
        source_id = config["insight_source_id"]
        organizations = config["organizations"]
        start_date = config.get("start_date")
        page_size_commits = config.get("page_size_graphql_commits", 100)
        page_size_prs = config.get("page_size_graphql_prs", 50)
        rate_limit_threshold = config.get("rate_limit_threshold", 200)
        skip_archived = config.get("skip_archived", True)
        skip_forks = config.get("skip_forks", True)
        max_workers = config.get("max_workers", 5)
        rate_limiter = RateLimiter(threshold=rate_limit_threshold)

        shared_kwargs = {
            "token": token,
            "tenant_id": tenant_id,
            "source_id": source_id,
            "rate_limiter": rate_limiter,
        }

        # Build stream dependency graph
        repos = RepositoriesStream(
            organizations=organizations,
            skip_archived=skip_archived,
            skip_forks=skip_forks,
            **shared_kwargs,
        )
        branches = BranchesStream(parent=repos, **shared_kwargs)
        commits = CommitsStream(
            parent=branches,
            page_size=page_size_commits,
            start_date=start_date,
            **shared_kwargs,
        )
        prs = PullRequestsStream(
            parent=repos,
            page_size=page_size_prs,
            **shared_kwargs,
        )

        return [
            repos,
            branches,
            commits,
            prs,
            FileChangesStream(
                pr_parent=prs, commits_parent=commits,
                max_workers=max_workers, **shared_kwargs,
            ),
            ReviewsStream(parent=prs, max_workers=max_workers, **shared_kwargs),
            CommentsStream(parent=prs, max_workers=max_workers, **shared_kwargs),
            PRCommitsStream(parent=prs, max_workers=max_workers, **shared_kwargs),
        ]


def main():
    source = SourceGitHub()
    # Airbyte CDK entrypoint
    from airbyte_cdk.entrypoint import launch
    launch(source, sys.argv[1:])


if __name__ == "__main__":
    main()

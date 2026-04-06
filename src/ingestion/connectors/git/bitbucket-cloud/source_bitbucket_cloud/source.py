"""Bitbucket Cloud Airbyte source connector (Python CDK)."""

import json
import logging
import sys
from pathlib import Path
from typing import Any, List, Mapping, Optional, Tuple

from airbyte_cdk.models import AirbyteConnectionStatus, Status
from airbyte_cdk.sources import AbstractSource
from airbyte_cdk.sources.streams import Stream

from source_bitbucket_cloud.clients.rate_limiter import RateLimiter
from source_bitbucket_cloud.streams.branches import BranchesStream
from source_bitbucket_cloud.streams.comments import PullRequestCommentsStream
from source_bitbucket_cloud.streams.commits import CommitsStream
from source_bitbucket_cloud.streams.file_changes import FileChangesStream
from source_bitbucket_cloud.streams.pr_commits import PRCommitsStream
from source_bitbucket_cloud.streams.pull_requests import PullRequestsStream
from source_bitbucket_cloud.streams.repositories import RepositoriesStream
from source_bitbucket_cloud.streams.reviews import PullRequestReviewsStream

logger = logging.getLogger("airbyte")


class SourceBitbucketCloud(AbstractSource):

    def spec(self, logger) -> Mapping[str, Any]:
        from airbyte_cdk.models import ConnectorSpecification
        spec_path = Path(__file__).parent / "spec.json"
        return ConnectorSpecification(**json.loads(spec_path.read_text()))

    def check_connection(self, logger, config) -> Tuple[bool, Optional[Any]]:
        """Validate auth and workspace access."""
        import requests
        from source_bitbucket_cloud.clients.auth import rest_headers

        username = config.get("username")
        token = config["token"]
        workspaces = config.get("workspaces", [])
        headers = rest_headers(username, token)

        try:
            for workspace in workspaces:
                resp = requests.get(
                    f"https://api.bitbucket.org/2.0/repositories/{workspace}?pagelen=1",
                    headers=headers,
                    timeout=10,
                )
                if resp.status_code == 404:
                    return False, f"Workspace '{workspace}' not found or not accessible with this token"
                if resp.status_code in (401, 403):
                    return False, f"Token lacks permission to access workspace '{workspace}' ({resp.status_code})"
                if resp.status_code != 200:
                    return False, f"Failed to access workspace '{workspace}' ({resp.status_code}): {resp.text[:200]}"

            return True, None
        except Exception as e:
            return False, str(e)

    def streams(self, config: Mapping[str, Any]) -> List[Stream]:
        username = config.get("username")
        token = config["token"]
        tenant_id = config["tenant_id"]
        source_instance_id = config["source_instance_id"]
        workspaces = config["workspaces"]
        start_date = config.get("start_date")
        rate_limit_threshold = config.get("rate_limit_threshold", 100)
        skip_forks = config.get("skip_forks", True)
        max_workers = config.get("max_workers", 3)
        rate_limiter = RateLimiter(threshold=rate_limit_threshold)

        shared_kwargs = {
            "username": username,
            "token": token,
            "tenant_id": tenant_id,
            "source_instance_id": source_instance_id,
            "rate_limiter": rate_limiter,
        }

        # Build stream dependency graph
        repos = RepositoriesStream(
            workspaces=workspaces,
            skip_forks=skip_forks,
            **shared_kwargs,
        )
        branches = BranchesStream(parent=repos, **shared_kwargs)
        commits = CommitsStream(
            parent=branches,
            start_date=start_date,
            **shared_kwargs,
        )
        prs = PullRequestsStream(parent=repos, **shared_kwargs)

        file_changes = FileChangesStream(
            pr_parent=prs,
            commits_parent=commits,
            max_workers=max_workers,
            **shared_kwargs,
        )
        reviews = PullRequestReviewsStream(
            parent=prs,
            max_workers=max_workers,
            **shared_kwargs,
        )
        comments = PullRequestCommentsStream(
            parent=prs,
            max_workers=max_workers,
            **shared_kwargs,
        )
        pr_commits = PRCommitsStream(
            parent=prs,
            max_workers=max_workers,
            **shared_kwargs,
        )

        return [repos, branches, commits, prs, file_changes, reviews, comments, pr_commits]


def main():
    source = SourceBitbucketCloud()
    from airbyte_cdk.entrypoint import launch
    launch(source, sys.argv[1:])


if __name__ == "__main__":
    main()

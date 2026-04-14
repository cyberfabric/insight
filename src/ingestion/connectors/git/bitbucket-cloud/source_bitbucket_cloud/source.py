"""Bitbucket Cloud Airbyte source connector (CDK-native)."""

import json
import logging
import sys
from pathlib import Path
from typing import Any, List, Mapping, Optional, Tuple

import requests
from airbyte_cdk.sources import AbstractSource
from airbyte_cdk.sources.streams import Stream

from source_bitbucket_cloud.auth import auth_headers

logger = logging.getLogger("airbyte")


class SourceBitbucketCloud(AbstractSource):
    """Entry-point for the Bitbucket Cloud Airbyte source connector."""

    def spec(self, logger: Any) -> Mapping[str, Any]:
        from airbyte_cdk.models import ConnectorSpecification

        spec_path = Path(__file__).parent / "spec.json"
        return ConnectorSpecification(**json.loads(spec_path.read_text()))

    def check_connection(
        self, logger: Any, config: Mapping[str, Any]
    ) -> Tuple[bool, Optional[Any]]:
        """Validate auth token and access to each configured workspace."""
        token = config["bitbucket_token"]
        username = config.get("bitbucket_username", "")
        workspaces = config.get("bitbucket_workspaces", [])
        headers = auth_headers(token, username)

        try:
            # Validate auth + workspace access in one pass.
            # We skip GET /user — it doesn't work for workspace access tokens.
            for workspace in workspaces:
                resp = requests.get(
                    f"https://api.bitbucket.org/2.0/repositories/{workspace}?pagelen=1",
                    headers=headers,
                    timeout=10,
                )
                if resp.status_code == 401:
                    return False, "Authentication failed: invalid or expired token"
                if resp.status_code == 404:
                    return False, (
                        f"Workspace '{workspace}' not found or not accessible "
                        f"with this token"
                    )
                if resp.status_code == 403:
                    return False, (
                        f"Token lacks permission to access workspace '{workspace}'"
                    )
                if resp.status_code != 200:
                    return False, (
                        f"Failed to access workspace '{workspace}' "
                        f"({resp.status_code}): {resp.text[:200]}"
                    )

            return True, None
        except requests.RequestException as exc:
            return False, f"Bitbucket API request failed: {exc}"

    def streams(self, config: Mapping[str, Any]) -> List[Stream]:
        """Build the stream dependency graph.

        Stream hierarchy::

            repos
            +-- branches
            |   +-- commits
            |       +-- file_changes
            +-- prs
                +-- pr_comments
                +-- pr_commits
        """
        token = config["bitbucket_token"]
        username = config.get("bitbucket_username", "")
        tenant_id = config["insight_tenant_id"]
        source_id = config["insight_source_id"]
        workspaces = config["bitbucket_workspaces"]
        start_date = config.get("bitbucket_start_date")
        skip_forks = config.get("bitbucket_skip_forks", True)

        shared = {
            "token": token,
            "username": username,
            "tenant_id": tenant_id,
            "source_id": source_id,
        }

        # -- Lazy imports to avoid circular dependencies at module level ----
        from source_bitbucket_cloud.streams.repositories import RepositoriesStream
        from source_bitbucket_cloud.streams.branches import BranchesStream
        from source_bitbucket_cloud.streams.commits import CommitsStream
        from source_bitbucket_cloud.streams.file_changes import FileChangesStream
        from source_bitbucket_cloud.streams.pull_requests import PullRequestsStream
        from source_bitbucket_cloud.streams.pr_comments import PRCommentsStream
        from source_bitbucket_cloud.streams.pr_commits import PRCommitsStream

        repos = RepositoriesStream(
            workspaces=workspaces,
            skip_forks=skip_forks,
            **shared,
        )
        branches = BranchesStream(parent=repos, **shared)
        commits = CommitsStream(parent=branches, start_date=start_date, **shared)
        file_changes = FileChangesStream(parent=commits, **shared)
        prs = PullRequestsStream(
            parent=repos, start_date=start_date, **shared,
        )
        pr_comments = PRCommentsStream(parent=prs, **shared)
        pr_commits = PRCommitsStream(parent=prs, **shared)

        return [
            repos,
            branches,
            prs,
            pr_comments,
            pr_commits,
            commits,        # slow — REST pagination across all branches
            file_changes,   # slowest — one REST call per commit
        ]


def main() -> None:
    """CLI entry-point (source-bitbucket-cloud-insight)."""
    source = SourceBitbucketCloud()
    from airbyte_cdk.entrypoint import launch

    launch(source, sys.argv[1:])


if __name__ == "__main__":
    main()

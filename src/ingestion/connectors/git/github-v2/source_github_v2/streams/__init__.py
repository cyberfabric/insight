"""GitHub v2 connector streams."""

from source_github_v2.streams.branches import BranchesStream
from source_github_v2.streams.commits import CommitsStream
from source_github_v2.streams.pull_requests import PullRequestsStream
from source_github_v2.streams.repositories import RepositoriesStream

__all__ = [
    "BranchesStream",
    "CommitsStream",
    "PullRequestsStream",
    "RepositoriesStream",
]

"""GraphQL query templates for GitHub API v4.

GraphQL for bulk listing (commits, PRs) and PR commit linkage.
REST for reviews, comments (simpler pagination).
"""

BULK_COMMIT_QUERY = """
query($owner: String!, $repo: String!, $branch: String!, $first: Int!, $after: String, $since: GitTimestamp) {
  repository(owner: $owner, name: $repo) {
    ref(qualifiedName: $branch) {
      target {
        ... on Commit {
          history(first: $first, after: $after, since: $since) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              oid
              message
              committedDate
              authoredDate
              additions
              deletions
              changedFilesIfAvailable
              author {
                name
                email
                user {
                  login
                  databaseId
                }
              }
              committer {
                name
                email
                user {
                  login
                  databaseId
                }
              }
              parents(first: 10) {
                nodes {
                  oid
                }
              }
            }
          }
        }
      }
    }
  }
  rateLimit {
    remaining
    resetAt
  }
}
"""

BULK_PR_QUERY = """
query($owner: String!, $repo: String!, $first: Int!, $after: String, $orderBy: IssueOrder!) {
  repository(owner: $owner, name: $repo) {
    pullRequests(first: $first, after: $after, orderBy: $orderBy, states: [OPEN, CLOSED, MERGED]) {
      pageInfo {
        hasNextPage
        endCursor
      }
      nodes {
        databaseId
        number
        title
        body
        state
        merged
        isDraft
        createdAt
        updatedAt
        closedAt
        mergedAt
        headRefName
        baseRefName
        additions
        deletions
        changedFiles
        author {
          login
          ... on User {
            databaseId
            email
          }
        }
        reviewDecision
        labels(first: 20) {
          nodes {
            name
          }
        }
        milestone {
          title
        }
        mergeCommit {
          oid
        }
        mergedBy {
          login
          ... on User {
            databaseId
          }
        }
        commits(first: 1) {
          totalCount
        }
        comments {
          totalCount
        }
        reviews {
          totalCount
        }
        reviewRequests(first: 20) {
          nodes {
            requestedReviewer {
              ... on User {
                login
                databaseId
              }
              ... on Team {
                name
                slug
              }
            }
          }
        }
      }
    }
  }
  rateLimit {
    remaining
    resetAt
  }
}
"""

PR_COMMITS_QUERY = """
query($owner: String!, $repo: String!, $prNumber: Int!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      commits(first: $first, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          commit {
            oid
            committedDate
          }
        }
      }
    }
  }
  rateLimit {
    remaining
    resetAt
  }
}
"""

REPO_METADATA_QUERY = """
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    databaseId
    name
    nameWithOwner
    description
    isPrivate
    isFork
    isArchived
    primaryLanguage {
      name
    }
    stargazerCount
    forkCount
    watchers {
      totalCount
    }
    issues(states: OPEN) {
      totalCount
    }
    defaultBranchRef {
      name
    }
    createdAt
    updatedAt
    pushedAt
  }
  rateLimit {
    remaining
    resetAt
  }
}
"""

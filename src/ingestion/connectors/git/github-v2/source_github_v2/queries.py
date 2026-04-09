"""GraphQL query templates for GitHub API v4.

Bulk listing (commits, PRs) and PR child entities
(reviews, comments, review threads, and PR commits).
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
    cost
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
        commits(first: __COMMITS_PAGE_SIZE__) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes { commit { oid committedDate } }
        }
        comments(first: __COMMENTS_PAGE_SIZE__) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            databaseId
            body
            createdAt
            updatedAt
            author {
              login
              ... on User { databaseId }
            }
            authorAssociation
          }
        }
        reviews(first: __REVIEWS_PAGE_SIZE__) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            databaseId
            state
            body
            submittedAt
            authorAssociation
            commit { oid }
            author {
              login
              ... on User { databaseId }
            }
          }
        }
        reviewThreads(first: __RT_PAGE_SIZE__) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            comments(first: __RTC_PAGE_SIZE__) {
              pageInfo { hasNextPage endCursor }
              nodes {
                databaseId
                body
                path
                line
                startLine
                diffHunk
                createdAt
                updatedAt
                author {
                  login
                  ... on User { databaseId }
                }
                authorAssociation
                commit { oid }
                originalCommit { oid }
                replyTo { databaseId }
              }
            }
          }
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
    cost
    remaining
    resetAt
  }
}
"""

PR_REVIEWS_QUERY = """
query($owner: String!, $repo: String!, $prNumber: Int!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviews(first: $first, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          databaseId
          state
          body
          submittedAt
          authorAssociation
          commit { oid }
          author {
            login
            ... on User { databaseId }
          }
        }
      }
    }
  }
  rateLimit {
    cost
    remaining
    resetAt
  }
}
"""

PR_COMMENTS_QUERY = """
query($owner: String!, $repo: String!, $prNumber: Int!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      comments(first: $first, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          databaseId
          body
          createdAt
          updatedAt
          author {
            login
            ... on User { databaseId }
          }
          authorAssociation
        }
      }
    }
  }
  rateLimit {
    cost
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
    cost
    remaining
    resetAt
  }
}
"""

PR_REVIEW_THREADS_QUERY = """
query($owner: String!, $repo: String!, $prNumber: Int!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: $first, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes {
              databaseId
              body
              path
              line
              startLine
              diffHunk
              createdAt
              updatedAt
              author {
                login
                ... on User { databaseId }
              }
              authorAssociation
              commit { oid }
              originalCommit { oid }
              replyTo { databaseId }
            }
          }
        }
      }
    }
  }
  rateLimit {
    cost
    remaining
    resetAt
  }
}
"""

PR_THREAD_COMMENTS_QUERY = """
query($threadId: ID!, $first: Int!, $after: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      isResolved
      comments(first: $first, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          databaseId
          body
          path
          line
          startLine
          diffHunk
          createdAt
          updatedAt
          author {
            login
            ... on User { databaseId }
          }
          authorAssociation
          commit { oid }
          originalCommit { oid }
          replyTo { databaseId }
        }
      }
    }
  }
  rateLimit {
    cost
    remaining
    resetAt
  }
}
"""


# GitHub Connector Specification

> Version 1.0 — March 2026
> Based on: Unified git data model (`docs/connectors/git/README.md`)

Standalone specification for the GitHub (Version Control) connector. Uses the unified `git_*` tables defined in `docs/connectors/git/README.md` with `data_source = "insight_github"`.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`github_graphql_cache` — Optional GraphQL query cache](#github_graphql_cache-optional-graphql-query-cache)
- [Silver Tables](#silver-tables)
  - [Unified Git Tables](#unified-git-tables)
- [API Details](#api-details)
  - [Base Configuration](#base-configuration)
  - [Authentication](#authentication)
  - [REST API v3 Endpoints](#rest-api-v3-endpoints)
  - [GraphQL API v4 Queries](#graphql-api-v4-queries)
  - [Rate Limiting](#rate-limiting)
- [Field Mapping to Unified Schema](#field-mapping-to-unified-schema)
  - [Repository Mapping](#repository-mapping)
  - [Commit Mapping (GraphQL)](#commit-mapping-graphql)
  - [Commit Mapping (REST Fallback)](#commit-mapping-rest-fallback)
  - [Pull Request Mapping (GraphQL)](#pull-request-mapping-graphql)
  - [PR Reviewer Mapping](#pr-reviewer-mapping)
  - [PR Comment Mapping](#pr-comment-mapping)
- [Collection Strategy](#collection-strategy)
  - [GraphQL Optimization](#graphql-optimization)
  - [Incremental Collection](#incremental-collection)
  - [Multi-Branch Collection](#multi-branch-collection)
  - [Error Handling](#error-handling)
- [Identity Resolution](#identity-resolution)
- [GitHub-Specific Considerations](#github-specific-considerations)
- [Open Questions](#open-questions)
  - [OQ-GH-1: Email privacy handling](#oq-gh-1-email-privacy-handling)
  - [OQ-GH-2: GraphQL cache retention policy](#oq-gh-2-graphql-cache-retention-policy)
  - [OQ-GH-3: Review state mapping](#oq-gh-3-review-state-mapping)

<!-- /toc -->

---

## Overview

**API**: GitHub REST API v3 + GraphQL API v4

**Category**: Version Control

**Authentication**: Personal Access Token (PAT), GitHub App installation token, or OAuth token

**Data Source Identifier**: `data_source = "insight_github"`

**Identity**: `author_email` (from commits) + `author_login` (GitHub username) — resolved to canonical `person_id` via Identity Manager. Email takes precedence when available; login is fallback when email is masked (e.g., `user@users.noreply.github.com`).

**Field naming**: GitHub uses camelCase in API responses (e.g., `createdAt`, `mergeCommit`) which are mapped to snake_case in the unified schema (`created_on`, `merge_commit_hash`).

**Why unified schema**: GitHub data is stored in the same `git_*` tables as Bitbucket and GitLab (defined in `docs/connectors/git/README.md`), using `data_source = "insight_github"` as the discriminator. This enables:
- Cross-platform analytics (e.g., "show all commits across GitHub and Bitbucket")
- Consistent identity resolution across git platforms
- Simplified Gold layer transformations
- Deduplication when repositories are mirrored

**GraphQL Advantages**: GitHub's GraphQL API v4 provides:
- **100x faster commit collection** (100 commits per request vs 1 per REST call)
- **50x faster PR collection** (50 PRs with nested data per request)
- **Reduced rate limit consumption** (fewer API calls for same data)
- **Rich nested data** (reviews, comments, commits in single query)

> **Note**: GitHub's formal review model distinguishes between `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, and `DISMISSED` states. This is more granular than Bitbucket's simple `APPROVED`/`UNAPPROVED` model. The unified schema accommodates both via the `status` field.

---

## Bronze Tables

### `github_graphql_cache` — Optional GraphQL query cache

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `cache_key` | String | REQUIRED | Cache key derived from query hash and variables (e.g., `commits:owner:repo:branch:cursor`) |
| `query_hash` | String | REQUIRED | MD5 hash of GraphQL query string |
| `query_variables` | String | REQUIRED | JSON-encoded GraphQL variables (e.g., `{"owner": "myorg", "repo": "myrepo"}`) |
| `response_body` | String | REQUIRED | Full GraphQL response body as JSON string |
| `response_status` | Int64 | REQUIRED | HTTP status code (e.g., 200, 401, 500) |
| `rate_limit_remaining` | Int64 | NULLABLE | GraphQL rate limit remaining after this request |
| `rate_limit_reset_at` | DateTime64(3) | NULLABLE | When rate limit resets |
| `cached_at` | DateTime64(3) | REQUIRED | When this response was cached |
| `expires_at` | DateTime64(3) | NULLABLE | Cache expiration timestamp (optional TTL) |
| `hit_count` | Int64 | DEFAULT 0 | Number of times this cached response was used |
| `data_source` | String | DEFAULT 'insight_github' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_cache_key`: `(cache_key, data_source)`
- `idx_query_hash`: `(query_hash)`
- `idx_expires_at`: `(expires_at)`

**Purpose**: Optional performance optimization table for caching GitHub GraphQL API responses. Reduces API calls and rate limit consumption for frequently accessed data (e.g., repository metadata, bulk commit queries).

**Cache key format**: `{query_type}:{owner}:{repo}:{additional_params}`

Examples:
- `repos:myorg:myrepo`
- `commits:myorg:myrepo:main:cursor=abc123`
- `prs:myorg:myrepo:state=all:cursor=xyz789`

**Usage pattern**:
```sql
-- Check cache before GraphQL query
SELECT response_body, cached_at, rate_limit_remaining
FROM github_graphql_cache
WHERE cache_key = 'commits:myorg:myrepo:main'
  AND data_source = 'insight_github'
  AND (expires_at IS NULL OR expires_at > NOW())
ORDER BY cached_at DESC
LIMIT 1;

-- Store GraphQL response
INSERT INTO github_graphql_cache (
  cache_key, query_hash, query_variables, response_body,
  response_status, rate_limit_remaining, rate_limit_reset_at,
  cached_at, data_source, _version
) VALUES (
  'commits:myorg:myrepo:main',
  md5('query { repository(...) { ... } }'),
  '{"owner": "myorg", "repo": "myrepo", "branch": "main"}',
  '{"data": {"repository": {...}}}',
  200,
  4999,
  NOW() + INTERVAL 1 HOUR,
  NOW(),
  'insight_github',
  toUnixTimestamp64Milli(NOW())
);
```

**Cache invalidation strategies**:
1. **TTL-based**: Set `expires_at` based on data volatility (e.g., repos: 24h, commits: 1h, PRs: 15min)
2. **Rate limit aware**: Cache aggressively when rate limit is low, skip cache when rate limit is high
3. **Event-based**: Invalidate on webhook events (PR merged, new commit pushed)
4. **Manual**: Periodic cache clearing for stale data

**Note**: This table is GitHub-specific and optional. Bitbucket connector may use different caching strategy (REST API response caching). The unified `git_*` tables do not require caching.

---

## Silver Tables

### Unified Git Tables

GitHub data is stored in the following unified Silver tables from `docs/connectors/git/README.md`:

| Table | Purpose | GitHub Usage |
|-------|---------|--------------|
| `git_repositories` | Repository metadata | Stores repos with `data_source = "insight_github"` |
| `git_repositories_ext` | Extended repo properties | Optional: stores GitHub-specific metrics (stars, forks, watchers, etc.) |
| `git_repository_branches` | Branch tracking for incremental sync | Tracks last collected commit per branch |
| `git_commits` | Commit history | Stores commits from all branches |
| `git_commits_ext` | Extended commit properties | Optional: stores AI analysis, license scanning results |
| `git_commit_files` | Per-file line changes | Parsed from commit diff data |
| `git_pull_requests` | PR metadata and lifecycle | Maps GitHub PRs with state normalization |
| `git_pull_requests_ext` | Extended PR properties | Optional: stores review metrics, cycle time calculations |
| `git_pull_requests_reviewers` | Review submissions | Maps GitHub reviewers from review events |
| `git_pull_requests_comments` | PR comments (general + inline) | Combines review comments and issue comments |
| `git_pull_requests_commits` | PR-to-commit junction table | Links PRs to their commits |
| `git_tickets` | Ticket references (Jira, etc.) | Extracts ticket keys from PR titles/descriptions and commit messages |
| `git_collection_runs` | Connector execution log | Tracks ETL run statistics and status |

**Reference**: See `docs/connectors/git/README.md` for complete table schemas, indexes, and field descriptions.

**Key mapping differences**:
- GitHub's `owner` + `repo_name` → `git_repositories.project_key` + `git_repositories.repo_slug`
- GitHub's `login` → stored in `author_name` fields
- GitHub's `databaseId` → stored in `pr_id` and `author_uuid` fields

---

## API Details

### Base Configuration

**Base URL**: `https://api.github.com`

**GraphQL Endpoint**: `https://api.github.com/graphql`

**API Versions**:
- **REST API v3**: `Accept: application/vnd.github.v3+json`
- **GraphQL API v4**: `Accept: application/vnd.github.v4+json`

---

### Authentication

**Preferred**: Personal Access Token (PAT) or GitHub App installation token

**Headers**:
```http
Authorization: Bearer {token}
Accept: application/vnd.github.v3+json
User-Agent: insight-github-connector/1.0
```

**Required Scopes** (for PAT):
- `repo` — Access to repositories (public and private)
- `read:org` — Read organization data
- `read:user` — Read user profile data

**GitHub App Permissions**:
- **Repositories**: Read-only
- **Pull Requests**: Read-only
- **Issues**: Read-only (for comments)
- **Metadata**: Read-only

---

### REST API v3 Endpoints

| Endpoint | Method | Purpose | Used For |
|----------|--------|---------|----------|
| `/orgs/{org}/repos` | GET | List organization repositories | Initial discovery |
| `/repos/{owner}/{repo}` | GET | Get repository details | Repository metadata |
| `/repos/{owner}/{repo}/branches` | GET | List branches | Branch tracking |
| `/repos/{owner}/{repo}/commits` | GET | List commits | Commit collection (fallback) |
| `/repos/{owner}/{repo}/commits/{sha}` | GET | Get commit details | Commit metadata (fallback) |
| `/repos/{owner}/{repo}/pulls` | GET | List pull requests | PR collection (fallback) |
| `/repos/{owner}/{repo}/pulls/{number}` | GET | Get PR details | PR metadata (fallback) |
| `/repos/{owner}/{repo}/pulls/{number}/reviews` | GET | Get PR reviews | Review submissions |
| `/repos/{owner}/{repo}/pulls/{number}/comments` | GET | Get PR review comments | Inline comments |
| `/repos/{owner}/{repo}/issues/{number}/comments` | GET | Get PR issue comments | General comments |
| `/repos/{owner}/{repo}/pulls/{number}/commits` | GET | Get PR commits | PR-to-commit linkage |
| `/repos/{owner}/{repo}/pulls/{number}/files` | GET | Get PR file changes | PR diffstat |

**Pagination** (REST v3):
```http
Link: <https://api.github.com/repos?page=2>; rel="next",
      <https://api.github.com/repos?page=10>; rel="last"
```

---

### GraphQL API v4 Queries

**Bulk Commit Query** (100 commits per request):

```graphql
query($owner: String!, $repo: String!, $branch: String!, $since: GitTimestamp, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    ref(qualifiedName: $branch) {
      target {
        ... on Commit {
          history(first: 100, since: $since, after: $cursor) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              oid
              message
              committedDate
              additions
              deletions
              changedFiles
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
              }
              parents(first: 5) {
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
```

**Bulk PR Query** (50 PRs per request with nested reviews/comments):

```graphql
query($owner: String!, $repo: String!, $cursor: String, $states: [PullRequestState!]) {
  repository(owner: $owner, name: $repo) {
    pullRequests(first: 50, after: $cursor, states: $states, orderBy: {field: UPDATED_AT, direction: DESC}) {
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
        createdAt
        updatedAt
        closedAt
        mergeCommit {
          oid
        }
        author {
          login
          ... on User {
            databaseId
            email
          }
        }
        headRefName
        baseRefName
        changedFiles
        additions
        deletions
        commits {
          totalCount
        }
        comments {
          totalCount
        }
        reviews(first: 100) {
          nodes {
            databaseId
            state
            submittedAt
            author {
              login
              ... on User {
                databaseId
                email
              }
            }
          }
        }
        comments(first: 100) {
          nodes {
            databaseId
            body
            createdAt
            updatedAt
            author {
              login
              ... on User {
                databaseId
              }
            }
          }
        }
        reviewThreads(first: 100) {
          nodes {
            comments(first: 100) {
              nodes {
                databaseId
                body
                path
                line
                createdAt
                updatedAt
                author {
                  login
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
```

**Repository Metadata Query**:

```graphql
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    databaseId
    name
    nameWithOwner
    description
    isPrivate
    primaryLanguage {
      name
    }
    diskUsage
    createdAt
    updatedAt
    pushedAt
    defaultBranchRef {
      name
    }
    isEmpty
    isFork
    forkCount
    stargazerCount
    watchers {
      totalCount
    }
    hasIssuesEnabled
    hasWikiEnabled
  }
}
```

---

### Rate Limiting

**GitHub Rate Limits**:
- **REST API v3**: 5,000 requests/hour (authenticated)
- **GraphQL API v4**: 5,000 points/hour (query complexity-based)
- **Unauthenticated**: 60 requests/hour (not recommended)

**GraphQL Point Calculation**:
- Base query: 1 point
- Each field: +1 point
- Each nested connection: +1 point per item
- Example: 100 commits query ≈ 110 points

**Rate Limit Headers** (REST):
```http
X-RateLimit-Limit: 5000
X-RateLimit-Remaining: 4999
X-RateLimit-Reset: 1678901234
```

**Rate Limit in GraphQL Response**:
```json
{
  "data": { ... },
  "rateLimit": {
    "remaining": 4999,
    "resetAt": "2026-03-05T12:00:00Z"
  }
}
```

**Best Practices**:
- **Prefer GraphQL** for bulk operations (commits, PRs)
- **Use REST as fallback** for individual item details
- **Monitor rate limit** and implement exponential backoff
- **Cache aggressively** when rate limit is low (<1000 remaining)
- **Use conditional requests** with `If-None-Match` (ETags)

---

## Field Mapping to Unified Schema

### Repository Mapping

**GitHub REST API** (`/repos/{owner}/{repo}`) → **`git_repositories`**:

```python
{
    # Primary keys
    'project_key': api_data['owner']['login'],           # e.g., "myorg"
    'repo_slug': api_data['name'],                       # e.g., "my-repo"
    'repo_uuid': str(api_data.get('id')) or None,        # e.g., "123456"
    
    # Metadata
    'name': api_data['name'],                            # Display name
    'full_name': api_data['full_name'],                  # e.g., "myorg/my-repo"
    'description': api_data.get('description'),          # May be null
    'is_private': 1 if api_data.get('private') else 0,
    
    # Timestamps
    'created_on': datetime.fromisoformat(api_data['created_at'].replace('Z', '+00:00')),
    'updated_on': datetime.fromisoformat(api_data['updated_at'].replace('Z', '+00:00')),
    
    # Platform-specific
    'size': api_data.get('size'),                        # KB
    'language': api_data.get('language'),                # Primary language
    'has_issues': 1 if api_data.get('has_issues') else 0,
    'has_wiki': 1 if api_data.get('has_wiki') else 0,
    
    # GitHub-specific (can be stored in _ext table)
    'fork_policy': 'forkable' if not api_data.get('disabled') else None,
    
    # System fields
    'metadata': json.dumps(api_data),
    'data_source': 'insight_github',
    '_version': int(time.time() * 1000)
}
```

**Optional `git_repositories_ext` properties** (GitHub-specific):

```python
# Store in git_repositories_ext for GitHub-specific metrics
ext_properties = [
    {'property_key': 'stars_count', 'property_value': str(api_data['stargazers_count']), 'property_type': 'int'},
    {'property_key': 'forks_count', 'property_value': str(api_data['forks_count']), 'property_type': 'int'},
    {'property_key': 'watchers_count', 'property_value': str(api_data['watchers_count']), 'property_type': 'int'},
    {'property_key': 'open_issues_count', 'property_value': str(api_data['open_issues_count']), 'property_type': 'int'},
    {'property_key': 'is_fork', 'property_value': str(int(api_data['fork'])), 'property_type': 'bool'},
    {'property_key': 'is_archived', 'property_value': str(int(api_data['archived'])), 'property_type': 'bool'},
    {'property_key': 'default_branch', 'property_value': api_data['default_branch'], 'property_type': 'string'},
]
```

---

### Commit Mapping (GraphQL)

**GitHub GraphQL** (bulk commit query) → **`git_commits`**:

```python
{
    # Primary keys
    'project_key': owner,
    'repo_slug': repo,
    'commit_hash': commit_node['oid'],                   # Full SHA-1 (40 chars)
    'branch': branch_name,                               # From query context
    
    # Author information
    'author_name': commit_node['author']['user']['login'] if commit_node['author'].get('user') else commit_node['author']['name'],
    'author_email': commit_node['author']['email'],      # May be noreply address
    'committer_name': commit_node['committer']['name'],
    'committer_email': commit_node['committer']['email'],
    
    # Commit details
    'message': commit_node['message'],
    'date': datetime.fromisoformat(commit_node['committedDate'].replace('Z', '+00:00')),
    'parents': json.dumps([p['oid'] for p in commit_node.get('parents', {}).get('nodes', [])]),
    
    # Statistics (from GraphQL)
    'files_changed': commit_node.get('changedFiles', 0),
    'lines_added': commit_node.get('additions', 0),
    'lines_removed': commit_node.get('deletions', 0),
    'is_merge_commit': 1 if len(commit_node.get('parents', {}).get('nodes', [])) > 1 else 0,
    
    # System fields
    'metadata': json.dumps(commit_node),
    'collected_at': datetime.now(),
    'data_source': 'insight_github',
    '_version': int(time.time() * 1000)
}
```

**Note**: GitHub GraphQL provides aggregate stats (`additions`, `deletions`, `changedFiles`) directly, eliminating the need for separate REST API calls for each commit.

---

### Commit Mapping (REST Fallback)

**GitHub REST API** (`/repos/{owner}/{repo}/commits/{sha}`) → **`git_commits`**:

```python
{
    # Primary keys
    'project_key': owner,
    'repo_slug': repo,
    'commit_hash': api_data['sha'],
    'branch': branch_name,
    
    # Author information
    'author_name': api_data['commit']['author']['name'],
    'author_email': api_data['commit']['author']['email'],
    'committer_name': api_data['commit']['committer']['name'],
    'committer_email': api_data['commit']['committer']['email'],
    
    # Commit details
    'message': api_data['commit']['message'],
    'date': datetime.fromisoformat(api_data['commit']['author']['date'].replace('Z', '+00:00')),
    'parents': json.dumps([p['sha'] for p in api_data.get('parents', [])]),
    
    # Statistics (from stats object)
    'files_changed': len(api_data.get('files', [])),
    'lines_added': api_data['stats']['additions'],
    'lines_removed': api_data['stats']['deletions'],
    'is_merge_commit': 1 if len(api_data.get('parents', [])) > 1 else 0,
    
    # System fields
    'metadata': json.dumps(api_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_github',
    '_version': int(time.time() * 1000)
}
```

**File-level changes** (`/repos/{owner}/{repo}/commits/{sha}`) → **`git_commit_files`**:

```python
for file_data in api_data.get('files', []):
    {
        'project_key': owner,
        'repo_slug': repo,
        'commit_hash': commit_hash,
        'file_path': file_data['filename'],
        'lines_added': file_data['additions'],
        'lines_removed': file_data['deletions'],
        'change_type': file_data['status'],              # added/modified/removed/renamed
        'metadata': json.dumps(file_data),
        'data_source': 'insight_github',
        '_version': int(time.time() * 1000)
    }
```

---

### Pull Request Mapping (GraphQL)

**GitHub GraphQL** (bulk PR query) → **`git_pull_requests`**:

```python
{
    # Primary keys
    'project_key': owner,
    'repo_slug': repo,
    'pr_id': pr_node['databaseId'],                      # Database ID
    'pr_number': pr_node['number'],                      # PR number (#123)
    
    # PR details
    'title': pr_node['title'],
    'description': pr_node.get('body', ''),
    'state': normalize_state(pr_node),                   # OPEN/MERGED/CLOSED
    
    # Author information
    'author_name': pr_node['author']['login'],
    'author_uuid': str(pr_node['author'].get('databaseId', '')),
    'author_email': pr_node['author'].get('email'),      # Often null due to privacy
    
    # Branch information
    'source_branch': pr_node['headRefName'],
    'destination_branch': pr_node['baseRefName'],
    
    # Timestamps
    'created_on': datetime.fromisoformat(pr_node['createdAt'].replace('Z', '+00:00')),
    'updated_on': datetime.fromisoformat(pr_node['updatedAt'].replace('Z', '+00:00')),
    'closed_on': datetime.fromisoformat(pr_node['closedAt'].replace('Z', '+00:00')) if pr_node.get('closedAt') else None,
    
    # Merge information
    'merge_commit_hash': pr_node.get('mergeCommit', {}).get('oid'),
    
    # Statistics
    'commit_count': pr_node['commits']['totalCount'],
    'comment_count': pr_node['comments']['totalCount'],
    'task_count': None,  # Not applicable to GitHub
    'files_changed': pr_node.get('changedFiles', 0),
    'lines_added': pr_node.get('additions', 0),
    'lines_removed': pr_node.get('deletions', 0),
    
    # Calculated fields
    'duration_seconds': calculate_duration(pr_node),
    
    # Ticket extraction
    'jira_tickets': extract_jira_tickets(pr_node),
    
    # System fields
    'metadata': json.dumps(pr_node),
    'collected_at': datetime.now(),
    'data_source': 'insight_github',
    '_version': int(time.time() * 1000)
}

def normalize_state(pr_node):
    """Normalize GitHub PR state to unified schema."""
    if pr_node['merged']:
        return 'MERGED'
    elif pr_node['state'] == 'CLOSED':
        return 'CLOSED'
    else:
        return 'OPEN'

def calculate_duration(pr_node):
    """Calculate PR duration in seconds."""
    created = datetime.fromisoformat(pr_node['createdAt'].replace('Z', '+00:00'))
    closed = pr_node.get('closedAt')
    if closed:
        closed = datetime.fromisoformat(closed.replace('Z', '+00:00'))
        return int((closed - created).total_seconds())
    return None
```

---

### PR Reviewer Mapping

**GitHub GraphQL** (PR reviews from bulk query) → **`git_pull_requests_reviewers`**:

```python
for review in pr_node['reviews']['nodes']:
    {
        # Primary keys
        'project_key': owner,
        'repo_slug': repo,
        'pr_id': pr_node['databaseId'],
        
        # Reviewer information
        'reviewer_name': review['author']['login'],
        'reviewer_uuid': str(review['author'].get('databaseId', '')),
        'reviewer_email': review['author'].get('email'),  # Often null
        
        # Review status
        'status': review['state'],                        # APPROVED/CHANGES_REQUESTED/COMMENTED/DISMISSED
        'role': 'REVIEWER',
        'approved': 1 if review['state'] == 'APPROVED' else 0,
        
        # Timestamp
        'reviewed_at': datetime.fromisoformat(review['submittedAt'].replace('Z', '+00:00')) if review.get('submittedAt') else None,
        
        # System fields
        'metadata': json.dumps(review),
        'collected_at': datetime.now(),
        'data_source': 'insight_github',
        '_version': int(time.time() * 1000)
    }
```

**GitHub review states**:
- `APPROVED` — Reviewer approved the changes
- `CHANGES_REQUESTED` — Reviewer requested changes
- `COMMENTED` — Reviewer commented without explicit approval/rejection
- `DISMISSED` — Review was dismissed (by PR author or admin)

---

### PR Comment Mapping

**GitHub GraphQL** (PR comments + review thread comments) → **`git_pull_requests_comments`**:

```python
# General PR comments (issue comments)
for comment in pr_node['comments']['nodes']:
    {
        # Primary keys
        'project_key': owner,
        'repo_slug': repo,
        'pr_id': pr_node['databaseId'],
        'comment_id': comment['databaseId'],
        
        # Comment content
        'content': comment['body'],
        
        # Author information
        'author_name': comment['author']['login'],
        'author_uuid': str(comment['author'].get('databaseId', '')),
        'author_email': comment['author'].get('email'),
        
        # Timestamps
        'created_at': datetime.fromisoformat(comment['createdAt'].replace('Z', '+00:00')),
        'updated_at': datetime.fromisoformat(comment['updatedAt'].replace('Z', '+00:00')),
        
        # GitHub-specific fields (null for general comments)
        'state': None,
        'severity': None,
        'thread_resolved': 0,
        
        # Inline comment location (null for general comments)
        'file_path': None,
        'line_number': None,
        
        # System fields
        'metadata': json.dumps(comment),
        'collected_at': datetime.now(),
        'data_source': 'insight_github',
        '_version': int(time.time() * 1000)
    }

# Inline review comments (review threads)
for thread in pr_node['reviewThreads']['nodes']:
    for comment in thread['comments']['nodes']:
        {
            # Primary keys
            'project_key': owner,
            'repo_slug': repo,
            'pr_id': pr_node['databaseId'],
            'comment_id': comment['databaseId'],
            
            # Comment content
            'content': comment['body'],
            
            # Author information
            'author_name': comment['author']['login'],
            'author_uuid': str(comment['author'].get('databaseId', '')),
            'author_email': comment['author'].get('email'),
            
            # Timestamps
            'created_at': datetime.fromisoformat(comment['createdAt'].replace('Z', '+00:00')),
            'updated_at': datetime.fromisoformat(comment['updatedAt'].replace('Z', '+00:00')),
            
            # GitHub-specific fields
            'state': None,
            'severity': None,
            'thread_resolved': 0,  # GitHub doesn't expose this in GraphQL
            
            # Inline comment location
            'file_path': comment.get('path'),
            'line_number': comment.get('line'),
            
            # System fields
            'metadata': json.dumps(comment),
            'collected_at': datetime.now(),
            'data_source': 'insight_github',
            '_version': int(time.time() * 1000)
        }
```

**Comment types**:
- **General PR comments**: From `comments` field (issue comments API)
- **Inline review comments**: From `reviewThreads` field (review comments on specific lines)

---

## Collection Strategy

### GraphQL Optimization

**Principle**: Use GraphQL for bulk operations to minimize API calls and rate limit consumption.

**Commit Collection Strategy**:

```python
def collect_commits_graphql(owner, repo, branch, since=None):
    """Collect commits using GraphQL (100 per request)."""
    commits = []
    cursor = None
    
    while True:
        # GraphQL query for 100 commits
        query = BULK_COMMIT_QUERY  # See API Details section
        variables = {
            'owner': owner,
            'repo': repo,
            'branch': f'refs/heads/{branch}',
            'since': since.isoformat() if since else None,
            'cursor': cursor
        }
        
        response = github_client.graphql(query, variables)
        history = response['data']['repository']['ref']['target']['history']
        
        # Parse commits
        for commit_node in history['nodes']:
            commit = parse_commit_graphql(commit_node, owner, repo, branch)
            commits.append(commit)
        
        # Check pagination
        if not history['pageInfo']['hasNextPage']:
            break
        cursor = history['pageInfo']['endCursor']
        
        # Check rate limit
        rate_limit = response['rateLimit']
        if rate_limit['remaining'] < 100:
            # Wait until rate limit resets
            reset_time = datetime.fromisoformat(rate_limit['resetAt'].replace('Z', '+00:00'))
            wait_seconds = (reset_time - datetime.now()).total_seconds()
            logger.warning(f"Rate limit low, waiting {wait_seconds}s...")
            time.sleep(wait_seconds)
    
    return commits
```

**PR Collection Strategy**:

```python
def collect_prs_graphql(owner, repo, states=['OPEN', 'CLOSED', 'MERGED']):
    """Collect PRs using GraphQL (50 per request with nested data)."""
    prs = []
    reviewers = []
    comments = []
    cursor = None
    
    while True:
        # GraphQL query for 50 PRs with reviews and comments
        query = BULK_PR_QUERY  # See API Details section
        variables = {
            'owner': owner,
            'repo': repo,
            'cursor': cursor,
            'states': states
        }
        
        response = github_client.graphql(query, variables)
        pr_connection = response['data']['repository']['pullRequests']
        
        # Parse PRs and nested data
        for pr_node in pr_connection['nodes']:
            pr = parse_pr_graphql(pr_node, owner, repo)
            prs.append(pr)
            
            # Parse reviews
            for review in pr_node['reviews']['nodes']:
                reviewer = parse_reviewer(review, owner, repo, pr_node['databaseId'])
                reviewers.append(reviewer)
            
            # Parse comments (general + inline)
            for comment in pr_node['comments']['nodes']:
                comment_obj = parse_comment(comment, owner, repo, pr_node['databaseId'])
                comments.append(comment_obj)
            
            for thread in pr_node['reviewThreads']['nodes']:
                for comment in thread['comments']['nodes']:
                    comment_obj = parse_inline_comment(comment, owner, repo, pr_node['databaseId'])
                    comments.append(comment_obj)
        
        # Check pagination
        if not pr_connection['pageInfo']['hasNextPage']:
            break
        cursor = pr_connection['pageInfo']['endCursor']
    
    return {'prs': prs, 'reviewers': reviewers, 'comments': comments}
```

**Performance comparison**:
- **GraphQL commits**: 100 commits/request × 50 requests = 5,000 commits (5,000 rate limit points)
- **REST commits**: 1 commit/request × 5,000 requests = 5,000 commits (5,000 rate limit points)
- **Result**: 100x fewer API calls with GraphQL

---

### Incremental Collection

**Principle**: Only fetch data that has changed since last collection run.

**Repository-level tracking**:
```sql
-- Get last update timestamp for repository
SELECT MAX(updated_on) as last_update
FROM git_pull_requests
WHERE project_key = 'myorg'
  AND repo_slug = 'myrepo'
  AND data_source = 'insight_github';
```

**Branch-level tracking** (for commits):
```sql
-- Get last collected commit per branch
SELECT branch_name, last_commit_hash, last_commit_date
FROM git_repository_branches
WHERE project_key = 'myorg'
  AND repo_slug = 'myrepo'
  AND data_source = 'insight_github';
```

**Collection algorithm**:
1. Fetch branches from `/repos/{owner}/{repo}/branches`
2. For each branch:
   - Check `git_repository_branches.last_commit_date`
   - Fetch commits using GraphQL with `since` parameter
   - Update `last_commit_hash` and `last_commit_date`
3. For PRs:
   - Fetch with `orderBy: {field: UPDATED_AT, direction: DESC}`
   - Early exit when `updated_on` < last collected update
4. For each PR:
   - Check if PR exists and `updated_on` hasn't changed → skip
   - Otherwise, collect full PR data (reviews, comments, commits)

---

### Multi-Branch Collection

**Principle**: Collect commits from all branches, not just default branch.

**Configuration**:
```python
COLLECT_ALL_BRANCHES = os.getenv('COLLECT_ALL_BRANCHES', 'true').lower() == 'true'
```

**Algorithm**:
```python
def collect_all_branches(owner, repo):
    """Collect commits from all branches."""
    branches = github_client.get_branches(owner, repo)
    all_commits = []
    seen_commits = set()
    
    for branch in branches:
        # Get last collected commit for this branch
        last_commit = get_last_commit_for_branch(owner, repo, branch.name)
        since = last_commit.date if last_commit else None
        
        # Collect commits
        commits = collect_commits_graphql(owner, repo, branch.name, since=since)
        
        # Deduplicate (commits can appear in multiple branches)
        for commit in commits:
            if commit['commit_hash'] not in seen_commits:
                all_commits.append(commit)
                seen_commits.add(commit['commit_hash'])
        
        # Update branch tracking
        update_branch_tracking(owner, repo, branch.name, commits)
    
    return all_commits
```

**Note**: Commits appearing in multiple branches are deduplicated by `commit_hash`. The `branch` field stores the first branch where the commit was encountered.

---

### Error Handling

**Error categories**:

1. **Authentication errors** (401, 403):
   - Log error and halt collection
   - Notify operators of credential/permission issues

2. **Rate limit errors** (403 with `rate limit exceeded` message):
   - Check `X-RateLimit-Reset` header
   - Wait until rate limit resets
   - Retry request

3. **Not found errors** (404):
   - Log warning (repository/PR may have been deleted or made private)
   - Continue with next item

4. **Server errors** (500, 502, 503):
   - Retry with exponential backoff (max 3 retries)
   - If persistent, log error and continue

5. **GraphQL errors**:
   - Check `errors` array in response
   - Log error details
   - Fall back to REST API if GraphQL query fails

**Retry logic**:
```python
def api_call_with_retry(func, max_retries=3, base_delay=1):
    """Execute API call with exponential backoff retry."""
    for attempt in range(max_retries):
        try:
            return func()
        except requests.HTTPError as e:
            if e.response.status_code == 403:
                # Check if rate limited
                if 'rate limit' in e.response.text.lower():
                    reset_time = int(e.response.headers.get('X-RateLimit-Reset', 0))
                    wait_seconds = reset_time - time.time()
                    logger.warning(f"Rate limited, waiting {wait_seconds}s...")
                    time.sleep(max(wait_seconds, 0))
                    continue
                else:
                    # Permission error, don't retry
                    raise
            elif e.response.status_code >= 500:
                delay = base_delay * (2 ** attempt)
                logger.error(f"Server error, retrying in {delay}s...")
                time.sleep(delay)
            elif e.response.status_code == 404:
                logger.warning(f"Resource not found: {e.response.url}")
                return None
            else:
                raise
    
    raise Exception(f"Max retries ({max_retries}) exceeded")
```

---

## Identity Resolution

**Primary identity key**: `author_email` from commits and `reviewer_email` from reviews

**GitHub-specific considerations**:
- **Email privacy**: Users can hide email addresses, resulting in `{user}@users.noreply.github.com` addresses
- **Multiple emails**: Users can have multiple emails (personal, work, noreply)
- **Username as fallback**: When email is masked, use `author_login` (GitHub username)

**Resolution process**:
1. Extract email from `git_commits.author_email` and `git_pull_requests_reviewers.reviewer_email`
2. Check if email is noreply address (`@users.noreply.github.com`)
   - If yes, use `author_name` (GitHub login) as fallback identifier
   - If no, use email as primary identifier
3. Normalize email (lowercase, trim)
4. Map to canonical `person_id` via Identity Manager
5. Store both email and login for cross-reference

**Cross-source matching**: Same person may have:
- GitHub email: `john@company.com` or `john@users.noreply.github.com`
- Bitbucket email: `john@company.com`
- GitHub login: `johndoe`
- Bitbucket username: `John.Doe`

Identity Manager uses email as primary key (when available), resolves to single `person_id`.

---

## GitHub-Specific Considerations

### Rich Metadata

GitHub provides more metadata than other git platforms:
- **Repository metrics**: Stars, forks, watchers, open issues count
- **Creation/update timestamps**: Available for repositories
- **Primary language detection**: Automatically detected
- **Fork status**: Indicates if repository is a fork

Store GitHub-specific metrics in `git_repositories_ext` table for consistency.

### Email Privacy

GitHub allows users to hide email addresses, resulting in:
- Commit email: `{user}@users.noreply.github.com` or `{id}+{user}@users.noreply.github.com`
- PR author email: Often null in API responses

**Handling strategy**:
1. Accept noreply emails as valid identifiers
2. Use `author_login` (username) as fallback for identity resolution
3. Attempt to resolve real email via Identity Manager's multi-identifier lookup

### Review Model

GitHub's review model is more granular than Bitbucket:

| Feature | GitHub | Bitbucket |
|---------|--------|-----------|
| Review states | `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` | `APPROVED`, `UNAPPROVED` |
| Required reviews | Enforced via branch protection | Enforced via repository settings |
| Review comments | Separate from review submission | Combined with review |
| Re-review requests | Supported | Not supported |

The unified schema accommodates both models via the `status` field.

### GraphQL Complexity

GitHub GraphQL queries have complexity limits:
- **Max complexity**: ~10,000 points per query
- **Nested pagination**: Limited to ~100 items per connection
- **Rate limit**: 5,000 points/hour

**Optimization strategies**:
- Fetch 50-100 items per request (balance between API calls and complexity)
- Use separate queries for deeply nested data (e.g., PR commits)
- Monitor `rateLimit` field in responses

---

## Open Questions

### OQ-GH-1: Email privacy handling

GitHub users can hide their email addresses, resulting in `{user}@users.noreply.github.com` addresses.

**Question**: Should we attempt to resolve real email addresses via GitHub's Users API or accept noreply emails as canonical identifiers?

**Options**:
1. **Accept noreply emails** as canonical identifiers (current approach)
2. **Attempt resolution** via `/users/{username}` API (requires additional API call, may still return null)
3. **Use login as primary** when email is noreply (may cause identity fragmentation)

**Current approach**: Accept noreply emails, use `author_login` as fallback in identity resolution

**Consideration**: Real emails are often unavailable even via Users API due to privacy settings

---

### OQ-GH-2: GraphQL cache retention policy

The optional `github_graphql_cache` table can grow unbounded without a retention policy.

**Question**: What is the recommended retention period for cached GraphQL responses?

**Options**:
1. **Short TTL** (15-60 minutes) for volatile data (PRs, commits)
2. **Long TTL** (24 hours) for stable data (repositories, branches)
3. **Rate limit aware** (aggressive caching when rate limit < 1000)
4. **Periodic purge** (delete entries older than 7 days)

**Current approach**: No automatic expiration — manual cache management required

**Consideration**: GitHub rate limit resets hourly, so 1-hour cache TTL aligns with rate limit cycle

---

### OQ-GH-3: Review state mapping

GitHub has 4 review states (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`) while Bitbucket has 2 (`APPROVED`, `UNAPPROVED`).

**Question**: How should we normalize review states in the unified schema for cross-platform analytics?

**Options**:
1. **Preserve as-is** (current approach) — store GitHub-specific states, handle in Silver layer
2. **Normalize to binary** — map `APPROVED` → 1, all others → 0
3. **Add source-specific mapping** — create lookup table for state normalization

**Current approach**: Preserve as-is, normalize in Gold layers based on analytics requirements

**Consideration**: Different platforms have different review semantics; preserving raw data provides most flexibility

---

# Bitbucket Server Connector Specification

> Version 1.0 — March 2026
> Based on: Unified git data model (`docs/connectors/git/README.md`)

Standalone specification for the Bitbucket Server/Data Center (Version Control) connector. Uses the unified `git_*` tables defined in `docs/connectors/git/README.md` with `data_source = "insight_bitbucket_server"`.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`bitbucket_api_cache` — Optional API response cache](#bitbucket_api_cache-optional-api-response-cache)
- [Silver Tables](#silver-tables)
  - [Unified Git Tables](#unified-git-tables)
- [API Details](#api-details)
  - [Base Configuration](#base-configuration)
  - [Key Endpoints](#key-endpoints)
  - [Pagination Pattern](#pagination-pattern)
- [Field Mapping to Unified Schema](#field-mapping-to-unified-schema)
  - [Repository Mapping](#repository-mapping)
  - [Commit Mapping](#commit-mapping)
  - [Pull Request Mapping](#pull-request-mapping)
  - [PR Reviewer Mapping](#pr-reviewer-mapping)
  - [PR Comment Mapping](#pr-comment-mapping)
- [Collection Strategy](#collection-strategy)
  - [Incremental Collection](#incremental-collection)
  - [Rate Limiting](#rate-limiting)
  - [Error Handling](#error-handling)
- [Identity Resolution](#identity-resolution)
- [Bitbucket-Specific Considerations](#bitbucket-specific-considerations)
- [Open Questions](#open-questions)
  - [OQ-BB-1: Author name format handling](#oq-bb-1-author-name-format-handling)
  - [OQ-BB-2: API cache retention policy](#oq-bb-2-api-cache-retention-policy)
  - [OQ-BB-3: Participant vs Reviewer distinction](#oq-bb-3-participant-vs-reviewer-distinction)

<!-- /toc -->

---

## Overview

**API**: Bitbucket Server REST API v1.0

**Category**: Version Control

**Authentication**: HTTP Basic Auth, Bearer Token, or Personal Access Token (PAT)

**Data Source Identifier**: `data_source = "insight_bitbucket_server"`

**Identity**: `author_email` (from commits) + `author_name` (Bitbucket username) — resolved to canonical `person_id` via Identity Manager. Email takes precedence; username is fallback when email is corporate-specific format or absent.

**Field naming**: Bitbucket uses camelCase in API responses (e.g., `displayId`, `authorTimestamp`) which are mapped to snake_case in the unified schema (`project_key`, `repo_slug`).

**Why unified schema**: Bitbucket data is stored in the same `git_*` tables as GitHub and GitLab (defined in `docs/connectors/git/README.md`), using `data_source = "insight_bitbucket_server"` as the discriminator. This enables:
- Cross-platform analytics (e.g., "show all commits across GitHub and Bitbucket")
- Consistent identity resolution across git platforms
- Simplified Gold layer transformations
- Deduplication when repositories are mirrored

> **Note**: Bitbucket Server's review model is simpler than GitHub's — reviewers can only `APPROVE` or `UNAPPROVE` (no `CHANGES_REQUESTED` or `COMMENTED` states). The unified schema accommodates both models via the `status` field normalization.

---

## Bronze Tables

### `bitbucket_api_cache` — Optional API response cache

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `cache_key` | String | REQUIRED | Cache key derived from endpoint and parameters (e.g., `commits:PROJ:repo-slug:main`) |
| `endpoint` | String | REQUIRED | API endpoint path (e.g., `/rest/api/1.0/projects/PROJ/repos/repo-slug/commits`) |
| `request_params` | String | REQUIRED | JSON-encoded request parameters (e.g., `{"until": "main", "limit": 100}`) |
| `response_body` | String | REQUIRED | Full API response body as JSON string |
| `response_status` | Int64 | REQUIRED | HTTP status code (e.g., 200, 404, 500) |
| `etag` | String | NULLABLE | ETag from response headers (for conditional requests) |
| `last_modified` | String | NULLABLE | Last-Modified header value |
| `cached_at` | DateTime64(3) | REQUIRED | When this response was cached |
| `expires_at` | DateTime64(3) | NULLABLE | Cache expiration timestamp (optional TTL) |
| `hit_count` | Int64 | DEFAULT 0 | Number of times this cached response was used |
| `data_source` | String | DEFAULT 'insight_bitbucket_server' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_cache_key`: `(cache_key, data_source)`
- `idx_endpoint`: `(endpoint)`
- `idx_expires_at`: `(expires_at)`

**Purpose**: Optional performance optimization table for caching Bitbucket API responses. Reduces API calls for frequently accessed data (e.g., repository metadata, branch lists) and enables offline processing during API outages.

**Cache key format**: `{endpoint_type}:{project_key}:{repo_slug}:{additional_params}`

Examples:
- `repos:PROJ:my-repo`
- `commits:PROJ:my-repo:main:until=abc123`
- `pr:PROJ:my-repo:12345`

**Usage pattern**:
```sql
-- Check cache before API call
SELECT response_body, cached_at
FROM bitbucket_api_cache
WHERE cache_key = 'repos:MYPROJ:my-repo'
  AND data_source = 'insight_bitbucket_server'
  AND (expires_at IS NULL OR expires_at > NOW())
ORDER BY cached_at DESC
LIMIT 1;

-- Store API response
INSERT INTO bitbucket_api_cache (
  cache_key, endpoint, request_params, response_body,
  response_status, cached_at, data_source, _version
) VALUES (
  'repos:MYPROJ:my-repo',
  '/rest/api/1.0/projects/MYPROJ/repos/my-repo',
  '{}',
  '{"slug": "my-repo", "name": "My Repo", ...}',
  200,
  NOW(),
  'insight_bitbucket_server',
  toUnixTimestamp64Milli(NOW())
);
```

**Cache invalidation strategies**:
1. **TTL-based**: Set `expires_at` based on data volatility (e.g., repos: 24h, commits: 1h)
2. **Event-based**: Invalidate on webhook events (PR merged, new commit)
3. **Manual**: Periodic cache clearing for stale data
4. **Conditional requests**: Use `etag`/`last_modified` for HTTP 304 Not Modified responses

**Note**: This table is Bitbucket-specific and optional. GitHub connector may use different caching strategy (e.g., GraphQL query result caching). The unified `git_*` tables do not require caching.

---

## Silver Tables

### Unified Git Tables

Bitbucket data is stored in the following unified Silver tables from `docs/connectors/git/README.md`:

| Table | Purpose | Bitbucket Usage |
|-------|---------|-----------------|
| `git_repositories` | Repository metadata | Stores projects and repos with `data_source = "insight_bitbucket_server"` |
| `git_repositories_ext` | Extended repo properties | Optional: stores aggregated metrics (total LOC, contributor counts, etc.) |
| `git_repository_branches` | Branch tracking for incremental sync | Tracks last collected commit per branch |
| `git_commits` | Commit history | Stores commits from all branches |
| `git_commits_ext` | Extended commit properties | Optional: stores AI analysis, license scanning results |
| `git_commit_files` | Per-file line changes | Parsed from `/commits/{hash}/diff` endpoint |
| `git_pull_requests` | PR metadata and lifecycle | Maps Bitbucket PRs with state normalization |
| `git_pull_requests_ext` | Extended PR properties | Optional: stores review metrics, cycle time calculations |
| `git_pull_requests_reviewers` | Review submissions | Maps Bitbucket reviewers from PR activities |
| `git_pull_requests_comments` | PR comments (general + inline) | Combines comments from activities endpoint |
| `git_pull_requests_commits` | PR-to-commit junction table | Links PRs to their commits |
| `git_tickets` | Ticket references (Jira, etc.) | Extracts Jira keys from PR titles/descriptions and commit messages |
| `git_collection_runs` | Connector execution log | Tracks ETL run statistics and status |

**Reference**: See `docs/connectors/git/README.md` for complete table schemas, indexes, and field descriptions.

**Key mapping differences**:
- Bitbucket's `project.key` → `git_repositories.project_key`
- Bitbucket's `repo.slug` → `git_repositories.repo_slug`
- GitHub's `owner` + `repo_name` maps to same fields for consistency

---

## API Details

### Base Configuration

**Base URL**: `https://git.company.com` (organization-specific)

**API Base Path**: `/rest/api/1.0`

**Authentication Headers**:
```http
Authorization: Bearer {token}
Content-Type: application/json
```

**Alternative Authentication**:
- HTTP Basic Auth: `Authorization: Basic {base64(username:password)}`
- Personal Access Token: `Authorization: Bearer {pat}`

---

### Key Endpoints

| Endpoint | Method | Purpose | Used For |
|----------|--------|---------|----------|
| `/rest/api/1.0/projects` | GET | List all projects | Initial discovery |
| `/rest/api/1.0/projects/{project}/repos` | GET | List repositories in project | Repository collection |
| `/rest/api/1.0/projects/{project}/repos/{repo}` | GET | Get repository details | Repository metadata |
| `/rest/api/1.0/projects/{project}/repos/{repo}/branches` | GET | List branches | Branch tracking |
| `/rest/api/1.0/projects/{project}/repos/{repo}/commits` | GET | List commits | Commit collection |
| `/rest/api/1.0/projects/{project}/repos/{repo}/commits/{hash}` | GET | Get commit details | Commit metadata |
| `/rest/api/1.0/projects/{project}/repos/{repo}/commits/{hash}/diff` | GET | Get commit diff | File-level line changes |
| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests` | GET | List pull requests | PR collection |
| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests/{id}` | GET | Get PR details | PR metadata |
| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests/{id}/activities` | GET | Get PR activities | Reviews, comments, approvals |
| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests/{id}/commits` | GET | Get PR commits | PR-to-commit linkage |
| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests/{id}/changes` | GET | Get PR file changes | PR diffstat |

---

### Pagination Pattern

All list endpoints use **server-side pagination**:

**Query parameters**:
- `start` — Page start index (default: 0)
- `limit` — Page size (default: 25, recommended: 100, max: 1000)

**Response structure**:
```json
{
  "size": 25,
  "limit": 100,
  "isLastPage": false,
  "start": 0,
  "nextPageStart": 100,
  "values": [
    {"/* item data */"}
  ]
}
```

**Pagination algorithm**:
```python
def paginate_endpoint(api_client, endpoint, **params):
    """Paginate through Bitbucket API endpoint."""
    start = 0
    limit = 100
    all_items = []

    while True:
        response = api_client.get(endpoint, params={
            **params,
            'start': start,
            'limit': limit
        })

        all_items.extend(response['values'])

        if response.get('isLastPage', True):
            break

        start = response['nextPageStart']

    return all_items
```

---

## Field Mapping to Unified Schema

### Repository Mapping

**Bitbucket API** (`/rest/api/1.0/projects/{project}/repos/{repo}`) → **`git_repositories`**:

```python
{
    # Primary keys
    'project_key': api_data['project']['key'],           # e.g., "MYPROJ"
    'repo_slug': api_data['slug'],                       # e.g., "my-repo"
    'repo_uuid': str(api_data.get('id')) or None,        # e.g., "368" (often null)

    # Metadata
    'name': api_data['name'],                            # Display name
    'full_name': None,                                   # Not available in Bitbucket
    'description': api_data.get('description'),          # May be null
    'is_private': 1 if not api_data.get('public') else 0,

    # Timestamps (not available in Bitbucket Server API)
    'created_on': None,
    'updated_on': None,

    # Platform-specific (not available)
    'size': None,
    'language': None,
    'has_issues': None,
    'has_wiki': None,

    # Bitbucket-specific
    'fork_policy': 'forkable' if api_data.get('forkable') else None,

    # System fields
    'metadata': json.dumps(api_data),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

---

### Commit Mapping

**Bitbucket API** (`/rest/api/1.0/projects/{p}/repos/{r}/commits/{hash}`) → **`git_commits`**:

```python
{
    # Primary keys
    'project_key': project_key,
    'repo_slug': repo_slug,
    'commit_hash': api_data['id'],                       # Full SHA-1 (40 chars)
    'branch': branch_name,                               # From query context

    # Author information
    'author_name': api_data['author']['name'],           # e.g., "John.Smith"
    'author_email': api_data['author']['emailAddress'],  # e.g., "john.smith@company.com"
    'committer_name': api_data['committer']['name'],
    'committer_email': api_data['committer']['emailAddress'],

    # Commit details
    'message': api_data['message'],
    'date': datetime.fromtimestamp(api_data['authorTimestamp'] / 1000),
    'parents': json.dumps([p['id'] for p in api_data.get('parents', [])]),

    # Statistics (from diff endpoint)
    'files_changed': len(diff_data.get('diffs', [])),
    'lines_added': calculate_lines_added(diff_data),
    'lines_removed': calculate_lines_removed(diff_data),
    'is_merge_commit': 1 if len(api_data.get('parents', [])) > 1 else 0,

    # System fields
    'metadata': json.dumps(api_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

**Note**: Bitbucket author names often use dot-separated format (e.g., "John.Smith") which differs from GitHub's format. Identity resolution must handle this variation.

---

### Pull Request Mapping

**Bitbucket API** (`/rest/api/1.0/projects/{p}/repos/{r}/pull-requests/{id}`) → **`git_pull_requests`**:

```python
{
    # Primary keys
    'project_key': project_key,
    'repo_slug': repo_slug,
    'pr_id': api_data['id'],                             # Database ID
    'pr_number': api_data['id'],                         # Same as pr_id in Bitbucket

    # PR details
    'title': api_data['title'],
    'description': api_data.get('description', ''),
    'state': normalize_state(api_data['state']),         # OPEN/MERGED/DECLINED

    # Author information
    'author_name': api_data['author']['user']['name'],
    'author_uuid': str(api_data['author']['user']['id']),

    # Branch information
    'source_branch': api_data['fromRef']['displayId'],
    'destination_branch': api_data['toRef']['displayId'],

    # Timestamps
    'created_on': datetime.fromtimestamp(api_data['createdDate'] / 1000),
    'updated_on': datetime.fromtimestamp(api_data['updatedDate'] / 1000),
    'closed_on': datetime.fromtimestamp(api_data['closedDate'] / 1000) if api_data.get('closedDate') else None,

    # Merge information
    'merge_commit_hash': api_data.get('properties', {}).get('mergeCommit', {}).get('id'),

    # Statistics
    'commit_count': None,  # Populated from /pull-requests/{id}/commits
    'comment_count': None, # Populated from activities
    'task_count': None,    # Bitbucket-specific — populated from activities
    'files_changed': None, # Populated from /pull-requests/{id}/changes
    'lines_added': None,
    'lines_removed': None,

    # Calculated fields
    'duration_seconds': calculate_duration(api_data),

    # Ticket extraction
    'jira_tickets': extract_jira_tickets(api_data),

    # System fields
    'metadata': json.dumps(api_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

**State normalization**:
- Bitbucket `OPEN` → `OPEN`
- Bitbucket `MERGED` → `MERGED`
- Bitbucket `DECLINED` → `DECLINED`

---

### PR Reviewer Mapping

**Bitbucket API** (`/rest/api/1.0/projects/{p}/repos/{r}/pull-requests/{id}/activities`) → **`git_pull_requests_reviewers`**:

Activities with `action` = `APPROVED` or `UNAPPROVED`, plus reviewers from PR details:

```python
{
    # Primary keys
    'project_key': project_key,
    'repo_slug': repo_slug,
    'pr_id': pr_id,

    # Reviewer information
    'reviewer_name': user_data['name'],                  # e.g., "bob"
    'reviewer_uuid': str(user_data['id']),
    'reviewer_email': user_data.get('emailAddress'),

    # Review status
    'status': api_data.get('status', 'UNAPPROVED'),     # APPROVED/UNAPPROVED
    'role': 'REVIEWER',
    'approved': 1 if api_data.get('status') == 'APPROVED' else 0,

    # Timestamp
    'reviewed_at': datetime.fromtimestamp(api_data['createdDate'] / 1000) if api_data.get('createdDate') else None,

    # System fields
    'metadata': json.dumps(api_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

**Note**: Bitbucket tracks reviewers in two places:
1. PR `reviewers` array (from PR details) — current review status
2. Activities with `APPROVED`/`UNAPPROVED` actions — historical review events

The connector should merge both sources to ensure completeness.

---

### PR Comment Mapping

**Bitbucket API** (`/rest/api/1.0/projects/{p}/repos/{r}/pull-requests/{id}/activities`) → **`git_pull_requests_comments`**:

Activities with `action` = `COMMENTED`:

```python
{
    # Primary keys
    'project_key': project_key,
    'repo_slug': repo_slug,
    'pr_id': pr_id,
    'comment_id': comment_data['id'],

    # Comment content
    'content': comment_data['text'],

    # Author information
    'author_name': user_data['name'],
    'author_uuid': str(user_data['id']),
    'author_email': user_data.get('emailAddress'),

    # Timestamps
    'created_at': datetime.fromtimestamp(comment_data['createdDate'] / 1000),
    'updated_at': datetime.fromtimestamp(comment_data['updatedDate'] / 1000),

    # Bitbucket-specific fields
    'state': comment_data.get('state'),                  # OPEN/RESOLVED
    'severity': comment_data.get('severity'),            # NORMAL/BLOCKER
    'thread_resolved': 1 if comment_data.get('threadResolved') else 0,

    # Inline comment location (if applicable)
    'file_path': comment_data.get('anchor', {}).get('path'),
    'line_number': comment_data.get('anchor', {}).get('line'),

    # System fields
    'metadata': json.dumps(comment_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

**Comment types**:
- **General comments**: `anchor` is null → `file_path` and `line_number` are NULL
- **Inline comments**: `anchor` contains file path and line → populated

---

## Collection Strategy

### Incremental Collection

**Principle**: Only fetch data that has changed since last collection run.

**Repository-level tracking**:
```sql
-- Get last update timestamp for repository
SELECT MAX(updated_on) as last_update
FROM git_pull_requests
WHERE project_key = 'MYPROJ'
  AND repo_slug = 'my-repo'
  AND data_source = 'insight_bitbucket_server';
```

**Branch-level tracking** (for commits):
```sql
-- Get last collected commit per branch
SELECT branch_name, last_commit_hash, last_commit_date
FROM git_repository_branches
WHERE project_key = 'MYPROJ'
  AND repo_slug = 'my-repo'
  AND data_source = 'insight_bitbucket_server';
```

**Collection algorithm**:
1. Fetch branches from `/branches` endpoint
2. For each branch:
   - Check `git_repository_branches.last_commit_hash`
   - Fetch commits until reaching last collected commit
   - Update `last_commit_hash` and `last_commit_date`
3. For PRs:
   - Fetch with `state=ALL`, `order=NEWEST`
   - Early exit when `updated_on` < last collected update
4. For each PR:
   - Check if PR already exists and `updated_on` hasn't changed → skip
   - Otherwise, collect full PR data (activities, commits, changes)

---

### Rate Limiting

**Bitbucket Server rate limits**: Typically not enforced by default, but may be configured by organization.

**Best practices**:
- Use `limit=100` for pagination (balance between API calls and response size)
- Implement exponential backoff on HTTP 429 (Too Many Requests)
- Add configurable sleep between requests (e.g., 100ms)

**Retry logic**:
```python
def api_call_with_retry(func, max_retries=3, base_delay=1):
    """Execute API call with exponential backoff retry."""
    for attempt in range(max_retries):
        try:
            return func()
        except requests.HTTPError as e:
            if e.response.status_code == 429:  # Rate limited
                delay = base_delay * (2 ** attempt)
                logger.warning(f"Rate limited, retrying in {delay}s...")
                time.sleep(delay)
            elif e.response.status_code >= 500:  # Server error
                delay = base_delay * (2 ** attempt)
                logger.error(f"Server error, retrying in {delay}s...")
                time.sleep(delay)
            else:
                raise

    raise Exception(f"Max retries ({max_retries}) exceeded")
```

---

### Error Handling

**Error categories**:

1. **Authentication errors** (401, 403):
   - Log error and halt collection
   - Notify operators of credential issues

2. **Not found errors** (404):
   - Log warning (repository/PR may have been deleted)
   - Continue with next item

3. **Server errors** (500, 502, 503):
   - Retry with exponential backoff
   - If persistent, log error and continue

4. **Malformed data**:
   - Log warning with API response
   - Skip malformed item
   - Continue collection

**Fault tolerance**:
- Checkpoint mechanism: Save progress after each repository
- Resume capability: Use `git_collection_runs` to track last processed repository
- Partial success: Mark run as `completed` even if some items failed (track error count)

---

## Identity Resolution

**Primary identity key**: `author_email` from commits and `reviewer_email` from reviews

**Bitbucket-specific considerations**:
- Email format is often corporate-specific (e.g., `john.smith@company.com`)
- Author name format uses dot-separation (e.g., `John.Smith`)
- User IDs are numeric (e.g., `152`, `660`)

**Resolution process**:
1. Extract email from `git_commits.author_email` and `git_pull_requests_reviewers.reviewer_email`
2. Normalize email (lowercase, trim)
3. Map to canonical `person_id` via Identity Manager
4. If email absent, attempt resolution by `author_name` with Bitbucket context
5. Fall back to `author_uuid` (Bitbucket user ID)

**Cross-source matching**: Same person may have:
- Bitbucket email: `john.smith@company.com`
- GitHub email: `john.smith@company.com` (same) or `jsmith@users.noreply.github.com` (different)
- Identity Manager uses email as primary key, resolves to single `person_id`

---

## Bitbucket-Specific Considerations

### Missing Metadata

Bitbucket Server API does **not** provide:
- Repository creation date (`created_on` = NULL)
- Repository size (`size` = NULL)
- Primary language detection (`language` = NULL)
- Issue tracker / wiki flags (`has_issues`, `has_wiki` = NULL)

These fields are nullable in the unified schema and will be NULL for Bitbucket sources.

### Task Count

Bitbucket supports inline **tasks** (checkboxes) in PR comments. This is tracked in `git_pull_requests.task_count` and is Bitbucket-specific (NULL for GitHub/GitLab).

### Review Model Differences

| Feature | Bitbucket | GitHub |
|---------|-----------|--------|
| Review states | `APPROVED`, `UNAPPROVED` | `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` |
| Comment severity | `NORMAL`, `BLOCKER` | Not supported |
| Thread resolution | Supported | Supported (different model) |
| Required approvals | Server-enforced | Server-enforced |

The unified schema accommodates both models:
- `status` field accepts all possible values
- Platform-specific values (e.g., `severity`) are nullable

### PR Participants vs Reviewers

Bitbucket tracks:
- **Reviewers**: Users explicitly added as reviewers
- **Participants**: Users who commented/interacted with PR

Current schema only tracks **reviewers** in `git_pull_requests_reviewers`. Participants are implicit from `git_pull_requests_comments.author_name`.

---

## Open Questions

### OQ-BB-1: Author name format handling

Bitbucket author names use dot-separated format (`John.Smith`) while GitHub uses various formats (`johndoe`, `John Doe`).

**Question**: Should we normalize author names in Silver layer or preserve as-is and normalize in Gold?

**Current approach**: Preserve as-is in Silver, normalize in Gold identity resolution

**Consideration**: Dot-separated names may be corporate standard, normalizing could lose information

---

### OQ-BB-2: API cache retention policy

The optional `bitbucket_api_cache` table can grow unbounded without a retention policy.

**Question**: What is the recommended retention period for cached API responses?

**Options**:
1. **Short TTL** (1-4 hours) for volatile data (commits, PRs)
2. **Long TTL** (24 hours) for stable data (repositories, branches)
3. **Event-based invalidation** (webhook triggers)
4. **Periodic purge** (delete entries older than 7 days)

**Current approach**: No automatic expiration — manual cache management required

---

### OQ-BB-3: Participant vs Reviewer distinction

Bitbucket distinguishes between:
- **Reviewers**: Formally assigned to review PR
- **Participants**: Commented or interacted with PR

**Question**: Should we add a separate `git_pull_requests_participants` table or merge into `git_pull_requests_reviewers` with a `role` field?

**Current approach**: Only store reviewers in `git_pull_requests_reviewers`, participants are implicit from comments

**Consideration**: Participants data is useful for collaboration analysis but may duplicate comment authors

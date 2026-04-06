# Git Connector Specification (Multi-Source)

> Version 1.0 — March 2026
> Based on: Unified git data model for Bitbucket, GitHub, and GitLab

Data-source agnostic specification for Version Control connectors. Defines unified Silver schemas that work across Bitbucket Server, GitHub, GitLab, and custom git sources using a `data_source` discriminator column. Bronze-level raw API data is defined in source-specific connector specs (e.g., `bitbucket.md`, `github.md`).

<!-- toc -->

- [Overview](#overview)
- [Silver Tables](#silver-tables)
  - [`git_repositories`](#git_repositories)
  - [`git_repositories_ext` — Extended repository properties](#git_repositories_ext-extended-repository-properties)
  - [`git_repository_branches`](#git_repository_branches)
  - [`git_commits`](#git_commits)
  - [`git_commits_ext` — Extended commit properties](#git_commits_ext-extended-commit-properties)
  - [`git_commit_files` — Per-file line changes](#git_commit_files-per-file-line-changes)
  - [`git_commits_files_ext` — Extended per-file properties](#git_commits_files_ext-extended-per-file-properties)
  - [`git_pull_requests`](#git_pull_requests)
  - [`git_pull_requests_ext` — Extended PR properties](#git_pull_requests_ext-extended-pr-properties)
  - [`git_pull_requests_reviewers` — Review submissions and approvals](#git_pull_requests_reviewers-review-submissions-and-approvals)
  - [`git_pull_requests_comments`](#git_pull_requests_comments)
  - [`git_pull_requests_commits`](#git_pull_requests_commits)
  - [`git_tickets` — Ticket references extracted from PRs and commits](#git_tickets-ticket-references-extracted-from-prs-and-commits)
  - [`git_collection_runs` — Connector execution log](#git_collection_runs-connector-execution-log)
- [Data Source Support](#data-source-support)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver--gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-GIT-1: Field naming standardization across sources](#oq-git-1-field-naming-standardization-across-sources)
  - [OQ-GIT-2: Handling source-specific features](#oq-git-2-handling-source-specific-features)
  - [OQ-GIT-3: Deduplication strategy for mirrored repositories](#oq-git-3-deduplication-strategy-for-mirrored-repositories)

<!-- /toc -->

---

## Overview

**Category**: Version Control

**Supported Sources**:
- Bitbucket Server (`data_source = "insight_bitbucket_server"`)
- GitHub (`data_source = "insight_github"`)
- GitLab (`data_source = "insight_gitlab"`)
- Custom ETL (`data_source = "custom_etl"`)

**Authentication**: 
- Bitbucket: HTTP Basic Auth or Personal Access Token
- GitHub: GitHub App installation token or Personal Access Token (PAT)
- GitLab: Personal Access Token or OAuth2

**Identity**: `author_email` (from commits) + `author_name`/`author_uuid` (source-specific username/ID) — resolved to canonical `person_id` via Identity Manager. Email takes precedence; username/UUID is fallback when email is absent or masked.

**Field naming**: Uses unified field names across all sources:
- Repository identification: `project_key` + `repo_slug`
- Primary keys: Auto-generated `id` column + composite natural keys
- Deduplication: `_version` column (UInt64 millisecond timestamp)

**Why multi-source design**: Organizations often use multiple git platforms (e.g., Bitbucket for internal, GitHub for open source) or mirror repositories across platforms. This unified schema enables:
- Single query across all git sources
- Consistent identity resolution regardless of source
- Global deduplication by `commit_hash`
- Simplified Gold layer transformation

**Source-specific fields**: Platform-specific features (e.g., GitHub's formal review states, Bitbucket's task count) are stored in the `metadata` JSON column and can be extracted in Gold layer if needed.

---

## Silver Tables

### `git_repositories`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework; partitions all data by customer |
| `insight_source_id` | String | REQUIRED | Source instance identifier (e.g. `github-acme-prod`) |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Organization/workspace/project key |
| `repo_slug` | String | REQUIRED | Repository name/slug |
| `repo_uuid` | String | NULLABLE | Source-specific unique ID (GitHub always populated, Bitbucket often null) |
| `name` | String | REQUIRED | Repository display name |
| `full_name` | String | NULLABLE | Full path (e.g., `org/repo` for GitHub) |
| `description` | String | NULLABLE | Repository description |
| `is_private` | Int64 | NULLABLE | 1 if private, 0 if public |
| `created_on` | DateTime64(3) | NULLABLE | Repository creation date (not available for Bitbucket Server) |
| `updated_on` | DateTime64(3) | NULLABLE | Last update timestamp |
| `size` | Int64 | NULLABLE | Repository size in KB (GitHub only) |
| `language` | String | NULLABLE | Primary programming language (GitHub only) |
| `has_issues` | Int64 | NULLABLE | 1 if issue tracker enabled (GitHub/GitLab) |
| `has_wiki` | Int64 | NULLABLE | 1 if wiki enabled (GitHub/GitLab) |
| `fork_policy` | String | NULLABLE | Fork policy (Bitbucket only) |
| `metadata` | String | REQUIRED | Full API response as JSON |
| `first_seen` | DateTime64(3) | NULLABLE | First time seen in our system |
| `last_updated` | DateTime64(3) | NULLABLE | Last time updated in our system |
| `last_commit_date` | DateTime64(3) | NULLABLE | Date of most recent commit |
| `last_commit_date_first_seen` | DateTime64(3) | NULLABLE | First time last_commit_date was observed |
| `last_commit_date_last_checked` | DateTime64(3) | NULLABLE | Last time last_commit_date was checked |
| `is_empty` | Int64 | NULLABLE | 1 if repository has no commits |
| `data_source` | String | DEFAULT '' | Source discriminator (insight_bitbucket_server, insight_github, insight_gitlab) |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

**Indexes**:
- `idx_repo_lookup`: `(project_key, repo_slug, data_source)`

**Source mapping**:
- **Bitbucket**: `project_key` ← `project.key`, `repo_slug` ← `slug`
- **GitHub**: `project_key` ← `owner.login`, `repo_slug` ← `name`
- **GitLab**: `project_key` ← `namespace.path`, `repo_slug` ← `path`

**Note**: Extended repository properties (aggregated statistics, analysis results, health metrics, etc.) are stored in the separate `git_repositories_ext` table to maintain schema flexibility.

---

### `git_repositories_ext` — Extended repository properties

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier (e.g. `github-acme-prod`) |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner — joins to `git_repositories.project_key` |
| `repo_slug` | String | REQUIRED | Repository name — joins to `git_repositories.repo_slug` |
| `field_id` | String | REQUIRED | Machine identifier for the property (e.g. `total_loc`, `code_health_score`) |
| `field_name` | String | REQUIRED | Human-readable label for the property (e.g. `"Total Lines of Code"`) |
| `field_value_str` | String | NULLABLE | String / JSON / enum value; NULL when the property is purely numeric |
| `field_value_int` | Int64 | NULLABLE | Integer or boolean (0/1) value; NULL when the property is not an integer |
| `field_value_float` | Float64 | NULLABLE | Fractional numeric value; NULL when the property is not a float |
| `collected_at` | DateTime64(3) | REQUIRED | When this property was collected/computed |
| `data_source` | String | DEFAULT '' | Source discriminator — joins to `git_repositories.data_source` |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Value column rules**: at least one of `field_value_str`, `field_value_int`, `field_value_float` must be non-NULL. Integer-valued properties (counts, flags) use `field_value_int`; fractional values use `field_value_float`; string, JSON, and enum values use `field_value_str`. Boolean flags use `field_value_int` with values `0` / `1`.

**Indexes**:
- `idx_repo_ext_lookup`: `(tenant_id, insight_source_id, project_key, repo_slug, field_id, data_source)`
- `idx_repo_field_id`: `(field_id)`

**Purpose**: Flexible key-value table for storing extended repository properties without modifying the core `git_repositories` schema. Enables addition of aggregated statistics, analysis results, and health metrics computed from commit/PR history without schema migrations.

**Common property keys**:

**Code statistics**:
- `total_loc` — Total lines of code across all files — value: `field_value_int`
- `total_files` — Total number of files in repository — value: `field_value_int`
- `language_breakdown` — Distribution of languages, e.g. `{"TypeScript": 45.2, "Python": 32.1, "Go": 22.7}` (percentages) — value: `field_value_str` (JSON)
- `loc_by_language` — Lines of code per language, e.g. `{"TypeScript": 12450, "Python": 8920}` — value: `field_value_str` (JSON)
- `binary_files_count` — Number of binary files — value: `field_value_int`
- `documentation_coverage` — Percentage of code with documentation — value: `field_value_float`

**Activity metrics**:
- `active_contributors_30d` — Number of unique contributors in last 30 days — value: `field_value_int`
- `active_contributors_90d` — Number of unique contributors in last 90 days — value: `field_value_int`
- `total_contributors` — Total unique contributors all-time — value: `field_value_int`
- `commit_frequency_30d` — Average commits per day in last 30 days — value: `field_value_float`
- `pr_frequency_30d` — Average PRs per day in last 30 days — value: `field_value_float`
- `last_activity_date` — Date of last commit or PR — value: `field_value_str` (ISO date)

**Quality metrics**:
- `code_health_score` — Overall code health score (0.0–100.0) — value: `field_value_float`
- `test_coverage_percentage` — Average test coverage across codebase — value: `field_value_float`
- `complexity_score` — Average code complexity metric — value: `field_value_float`
- `technical_debt_ratio` — Ratio of technical debt to total code — value: `field_value_float`
- `code_duplication_percentage` — Percentage of duplicated code — value: `field_value_float`
- `security_vulnerabilities_count` — Number of known security vulnerabilities — value: `field_value_int`
- `license_compliance_score` — License compliance score (0.0–100.0) — value: `field_value_float`

**AI analysis**:
- `ai_generated_percentage` — Estimated percentage of AI-generated code — value: `field_value_float`
- `third_party_code_percentage` — Percentage of third-party code — value: `field_value_float`
- `third_party_licenses` — List of detected third-party licenses — value: `field_value_str` (JSON)

**Repository health**:
- `is_archived` — Repository is archived (0 or 1) — value: `field_value_int`
- `is_stale` — No activity in last 90 days (0 or 1) — value: `field_value_int`
- `is_monorepo` — Repository is a monorepo (0 or 1) — value: `field_value_int`
- `primary_framework` — Main framework/stack detected (e.g., "React", "Django") — value: `field_value_str`
- `deployment_frequency_30d` — Deployments per day in last 30 days — value: `field_value_float`
- `mean_time_to_recovery` — Average time to fix production issues (hours) — value: `field_value_float`

**Collaboration metrics**:
- `avg_pr_cycle_time_hours` — Average PR cycle time in hours — value: `field_value_float`
- `avg_review_depth_score` — Average review quality score — value: `field_value_float`
- `bus_factor` — Number of people needed to lose to stall project — value: `field_value_int`
- `contributor_diversity_score` — Distribution evenness of contributions (0.0–1.0) — value: `field_value_float`

**Trend data**:
- `loc_trend_30d` — LOC change over last 30 days — value: `field_value_str` (JSON time series)
- `contributor_trend_90d` — Contributor count trend over last 90 days — value: `field_value_str` (JSON time series)
- `velocity_trend_30d` — Commit/PR velocity trend — value: `field_value_str` (JSON time series)

**Usage example**:
```sql
-- Get total LOC for a specific repository
SELECT field_value_int 
FROM git_repositories_ext 
WHERE project_key = 'MyOrg' 
  AND repo_slug = 'my-repo'
  AND field_id = 'total_loc'
  AND data_source = 'insight_github';

-- Get language breakdown for all repositories in an org
SELECT r.repo_slug, ext.field_value_str AS language_breakdown
FROM git_repositories r
JOIN git_repositories_ext ext 
  ON r.project_key = ext.project_key 
  AND r.repo_slug = ext.repo_slug
  AND r.data_source = ext.data_source
WHERE r.project_key = 'MyOrg'
  AND ext.field_id = 'language_breakdown';

-- Find all stale repositories (boolean flag stored as int 0/1)
SELECT r.project_key, r.repo_slug, r.last_commit_date
FROM git_repositories r
JOIN git_repositories_ext ext 
  ON r.project_key = ext.project_key 
  AND r.repo_slug = ext.repo_slug
  AND r.data_source = ext.data_source
WHERE ext.field_id = 'is_stale'
  AND ext.field_value_int = 1;

-- Aggregate code health metrics — no casting needed
SELECT 
  r.repo_slug,
  MAX(CASE WHEN ext.field_id = 'code_health_score'       THEN ext.field_value_float END) AS health_score,
  MAX(CASE WHEN ext.field_id = 'test_coverage_percentage' THEN ext.field_value_float END) AS test_coverage,
  MAX(CASE WHEN ext.field_id = 'complexity_score'        THEN ext.field_value_float END) AS complexity
FROM git_repositories r
JOIN git_repositories_ext ext 
  ON r.project_key = ext.project_key 
  AND r.repo_slug = ext.repo_slug
  AND r.data_source = ext.data_source
WHERE r.is_empty = 0
  AND ext.field_id IN ('code_health_score', 'test_coverage_percentage', 'complexity_score')
GROUP BY r.repo_slug;
```

**Design rationale**: 
- **Aggregated metrics**: Store computed statistics that would be expensive to calculate on-demand
- **Time-series data**: Track trends without schema changes
- **Periodic updates**: Metrics can be recomputed daily/weekly via `collected_at` timestamp
- **Flexibility**: Add new health metrics as analysis capabilities evolve
- **Efficiency**: Pre-computed values enable fast dashboard queries
- **Historical tracking**: Multiple `collected_at` values show metric evolution over time

---

### `git_repository_branches`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier (e.g. `bitbucket-acme-prod`) |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `branch_name` | String | REQUIRED | Branch name |
| `is_default` | Int64 | REQUIRED | 1 if default branch, 0 otherwise |
| `last_commit_hash` | String | NULLABLE | Last commit collected from this branch — cursor for incremental sync |
| `last_commit_date` | DateTime64(3) | NULLABLE | Date of last commit |
| `last_checked_at` | String | NULLABLE | Last time this branch was checked (millisecond timestamp string) |
| `metadata` | String | NULLABLE | Branch metadata as JSON |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_branch_lookup`: `(project_key, repo_slug, branch_name, data_source)`

**Purpose**: Track branch state for incremental collection. The `last_commit_hash` serves as a cursor — only commits after this hash need to be fetched on subsequent runs.

---

### `git_commits`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier (e.g. `github-acme-prod`) |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `commit_hash` | String | REQUIRED | Git SHA-1 hash (40 characters) — natural deduplication key |
| `branch` | String | NULLABLE | Branch where commit was found |
| `author_name` | String | REQUIRED | Commit author name |
| `author_email` | String | REQUIRED | Author email — primary identity key for cross-system resolution |
| `committer_name` | String | REQUIRED | Committer name |
| `committer_email` | String | REQUIRED | Committer email |
| `message` | String | REQUIRED | Commit message |
| `date` | DateTime64(3) | REQUIRED | Commit timestamp |
| `parents` | String | REQUIRED | JSON array of parent commit hashes — length > 1 indicates merge commit |
| `files_changed` | Int64 | NULLABLE | Number of files modified |
| `lines_added` | Int64 | NULLABLE | Total lines added |
| `lines_removed` | Int64 | NULLABLE | Total lines removed |
| `is_merge_commit` | Int64 | NULLABLE | 1 if merge commit (multiple parents), 0 otherwise |
| `metadata` | String | REQUIRED | Full API response as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_commit_lookup`: `(project_key, repo_slug, commit_hash, data_source)`
- `idx_commit_date`: `(date)`

**Deduplication**: Same `commit_hash` may appear from multiple sources if repository is mirrored. The `data_source` column distinguishes records, but analytics should typically `COUNT(DISTINCT commit_hash)` to avoid double-counting.

**Note**: Extended commit properties (AI analysis, license scanning, language breakdown, etc.) are stored in the separate `git_commits_ext` table to maintain schema flexibility.

---

### `git_commits_ext` — Extended commit properties

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner — joins to `git_commits.project_key` |
| `repo_slug` | String | REQUIRED | Repository name — joins to `git_commits.repo_slug` |
| `commit_hash` | String | REQUIRED | Commit SHA — joins to `git_commits.commit_hash` |
| `field_id` | String | REQUIRED | Machine identifier for the property (e.g. `ai_percentage`, `scancode_metadata`) |
| `field_name` | String | REQUIRED | Human-readable label for the property (e.g. `"AI-generated percentage"`) |
| `field_value_str` | String | NULLABLE | String / JSON / enum value; NULL when the property is purely numeric |
| `field_value_int` | Int64 | NULLABLE | Integer or boolean (0/1) value; NULL when the property is not an integer |
| `field_value_float` | Float64 | NULLABLE | Fractional numeric value; NULL when the property is not a float |
| `collected_at` | DateTime64(3) | REQUIRED | When this property was collected/computed |
| `data_source` | String | DEFAULT '' | Source discriminator — joins to `git_commits.data_source` |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Value column rules**: at least one of `field_value_str`, `field_value_int`, `field_value_float` must be non-NULL. Boolean flags use `field_value_int` (`0`/`1`); fractional scores use `field_value_float`; JSON and string values use `field_value_str`.

**Indexes**:
- `idx_commit_ext_lookup`: `(tenant_id, insight_source_id, project_key, repo_slug, commit_hash, field_id, data_source)`
- `idx_commit_ext_field_id`: `(field_id)`

**Purpose**: Flexible key-value table for storing extended commit properties without modifying the core `git_commits` schema. Enables addition of new analysis results (AI detection, license scanning, security analysis, code quality metrics) without schema migrations.

**Common property keys**:
- `ai_percentage` — AI-generated code estimate (0.0–1.0) — value: `field_value_float`
- `ai_thirdparty_flag` — AI-detected third-party code (0 or 1) — value: `field_value_int`
- `ai_thirdparty_repos` — Third-party repository detection metadata — value: `field_value_str` (JSON)
- `scancode_metadata` — License and copyright scanning results — value: `field_value_str` (JSON)
- `scancode_thirdparty_flag` — License scanner detected third-party (0 or 1) — value: `field_value_int`
- `language_breakdown` — Lines per language, e.g. `{"TypeScript": 120, "Python": 45}` — value: `field_value_str` (JSON)
- `hash_sum` — Deduplication hash for multi-file commits — value: `field_value_str`
- `security_scan_results` — Security vulnerability scan results — value: `field_value_str` (JSON)
- `code_quality_score` — Static analysis quality score — value: `field_value_float`
- `test_coverage_delta` — Change in test coverage from this commit — value: `field_value_float`

**Usage example**:
```sql
-- Get AI percentage for a specific commit (no casting needed)
SELECT field_value_float
FROM git_commits_ext
WHERE tenant_id = '...'
  AND commit_hash = 'abc123...'
  AND field_id = 'ai_percentage'
  AND data_source = 'insight_github';

-- Find all third-party flagged commits (integer comparison, no string cast)
SELECT commit_hash, field_value_int AS ai_thirdparty
FROM git_commits_ext
WHERE tenant_id = '...'
  AND project_key = 'MyOrg'
  AND repo_slug = 'my-repo'
  AND field_id = 'ai_thirdparty_flag'
  AND field_value_int = 1;

-- Average AI percentage across a repo
SELECT AVG(field_value_float) AS avg_ai_pct
FROM git_commits_ext
WHERE tenant_id = '...'
  AND project_key = 'MyOrg'
  AND repo_slug = 'my-repo'
  AND field_id = 'ai_percentage';
```

**Design rationale**: 
- **Flexibility**: Add new properties without schema changes
- **Efficiency**: Query only needed properties via index on `field_id`
- **Versioning**: Track when each property was computed via `collected_at`
- **Normalization**: Avoid wide table with many NULL values
- **Evolution**: Properties can be deprecated or renamed without data migration

---

### `git_commit_files` — Per-file line changes

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `commit_hash` | String | REQUIRED | Parent commit SHA — joins to `git_commits.commit_hash` |
| `diff_hash` | String | REQUIRED | SHA-256 hash of diff content for deduplication |
| `file_path` | String | REQUIRED | Full file path |
| `file_extension` | String | NULLABLE | File extension (e.g., "py", "java", "ts") |
| `lines_added` | Int64 | NULLABLE | Lines added in this file |
| `lines_removed` | Int64 | NULLABLE | Lines removed in this file |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | REQUIRED | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_file_lookup`: `(project_key, repo_slug, commit_hash, file_path, data_source)`

**Purpose**: Granular file-level analysis for commit impact. Enables queries like "show all changes to authentication files" or "calculate churn per directory."

**Note**: Extended per-file properties (AI detection flags, license scanning results) are stored in the separate `git_commits_files_ext` table to maintain schema flexibility.

---

### `git_commits_files_ext` — Extended per-file properties

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner — joins to `git_commit_files.project_key` |
| `repo_slug` | String | REQUIRED | Repository name — joins to `git_commit_files.repo_slug` |
| `commit_hash` | String | REQUIRED | Commit SHA — joins to `git_commit_files.commit_hash` |
| `file_path` | String | REQUIRED | File path — joins to `git_commit_files.file_path` |
| `field_id` | String | REQUIRED | Machine identifier for the property (e.g. `ai_thirdparty_flag`, `scancode_metadata`) |
| `field_name` | String | REQUIRED | Human-readable label for the property (e.g. `"AI Third-party Flag"`) |
| `field_value_str` | String | NULLABLE | String / JSON value; NULL when the property is purely numeric |
| `field_value_int` | Int64 | NULLABLE | Integer or boolean (0/1) value; NULL when the property is not an integer |
| `field_value_float` | Float64 | NULLABLE | Fractional numeric value; NULL when the property is not a float |
| `collected_at` | DateTime64(3) | REQUIRED | When this property was collected/computed |
| `data_source` | String | DEFAULT '' | Source discriminator — joins to `git_commit_files.data_source` |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Value column rules**: at least one of `field_value_str`, `field_value_int`, `field_value_float` must be non-NULL. Boolean flags use `field_value_int` (`0`/`1`); JSON results use `field_value_str`.

**Indexes**:
- `idx_commit_file_ext_lookup`: `(tenant_id, insight_source_id, project_key, repo_slug, commit_hash, file_path, field_id, data_source)`
- `idx_file_ext_field_id`: `(field_id)`

**Purpose**: Flexible key-value table for storing extended per-file properties without modifying the core `git_commit_files` schema. Enables addition of new file-level analysis results (AI detection, license scanning, security analysis) without schema migrations.

**Common property keys**:
- `ai_thirdparty_flag` — AI-detected third-party code (0 or 1) — value: `field_value_int`
- `scancode_thirdparty_flag` — License scanner detected third-party (0 or 1) — value: `field_value_int`
- `scancode_metadata` — License and copyright scanning results for this file — value: `field_value_str` (JSON)

**Usage example**:
```sql
-- Find all files with third-party code in a repository (integer comparison, no cast)
SELECT cf.commit_hash, cf.file_path, cf.file_extension,
       ext.field_id, ext.field_value_int
FROM git_commit_files cf
JOIN git_commits_files_ext ext
  ON cf.tenant_id = ext.tenant_id
  AND cf.project_key = ext.project_key
  AND cf.repo_slug = ext.repo_slug
  AND cf.commit_hash = ext.commit_hash
  AND cf.file_path = ext.file_path
  AND cf.data_source = ext.data_source
WHERE cf.tenant_id = '...'
  AND cf.project_key = 'MyOrg'
  AND cf.repo_slug = 'my-repo'
  AND ext.field_id IN ('ai_thirdparty_flag', 'scancode_thirdparty_flag')
  AND ext.field_value_int = 1;

-- Get scancode metadata (JSON) for all files in a commit
SELECT file_path, field_value_str AS scancode_metadata
FROM git_commits_files_ext
WHERE commit_hash = 'abc123...'
  AND field_id = 'scancode_metadata'
  AND data_source = 'insight_bitbucket_server';
```

**Design rationale**:
- **Flexibility**: Add new per-file properties without schema changes
- **Efficiency**: Query only needed properties via index on `field_id`
- **Versioning**: Track when each property was computed via `collected_at`
- **Normalization**: Avoid wide table with many NULL values
- **Evolution**: Properties can be deprecated or renamed without data migration
- **Optional enrichment**: Not every deployment runs AI detection or ScanCode; rows are only inserted when those pipelines are active

---

### `git_pull_requests`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | REQUIRED | PR database ID from source API |
| `pr_number` | Int64 | REQUIRED | PR display number (user-facing) |
| `title` | String | REQUIRED | PR title |
| `description` | String | NULLABLE | PR body/description (Markdown) |
| `state` | String | REQUIRED | PR state — normalized to: `OPEN`, `MERGED`, `CLOSED`, `DECLINED` |
| `author_name` | String | REQUIRED | PR author username |
| `author_uuid` | String | REQUIRED | Author unique identifier from source |
| `created_on` | DateTime64(3) | REQUIRED | PR creation timestamp |
| `updated_on` | DateTime64(3) | REQUIRED | Last update timestamp |
| `closed_on` | DateTime64(3) | NULLABLE | Close/merge timestamp (NULL if still open) |
| `merge_commit_hash` | String | NULLABLE | Hash of merge commit (NULL if not merged) |
| `source_branch` | String | REQUIRED | Source/head branch name |
| `destination_branch` | String | REQUIRED | Target/base branch name |
| `commit_count` | Int64 | NULLABLE | Number of commits in PR |
| `comment_count` | Int64 | NULLABLE | Number of general discussion comments |
| `task_count` | Int64 | NULLABLE | Number of tasks (Bitbucket only — NULL for GitHub/GitLab) |
| `files_changed` | Int64 | NULLABLE | Number of files modified |
| `lines_added` | Int64 | NULLABLE | Total lines added |
| `lines_removed` | Int64 | NULLABLE | Total lines removed |
| `duration_seconds` | Int64 | NULLABLE | Time from creation to close in seconds |
| `jira_tickets` | String | NULLABLE | JSON array of extracted Jira ticket IDs, e.g. `["PROJ-123", "PROJ-456"]` |
| `metadata` | String | REQUIRED | Full API response as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_pr_lookup`: `(project_key, repo_slug, pr_id, data_source)`
- `idx_pr_updated`: `(updated_on)`
- `idx_pr_state`: `(state)`

**State normalization**:
- Bitbucket: `OPEN`, `MERGED`, `DECLINED` → maps directly
- GitHub: `open` → `OPEN`, `closed` + `merged=true` → `MERGED`, `closed` + `merged=false` → `CLOSED`
- GitLab: `opened` → `OPEN`, `merged` → `MERGED`, `closed` → `CLOSED`

**Note**: Extended PR properties (AI analysis, review metrics, quality scores, etc.) are stored in the separate `git_pull_requests_ext` table to maintain schema flexibility.

---

### `git_pull_requests_ext` — Extended PR properties

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner — joins to `git_pull_requests.project_key` |
| `repo_slug` | String | REQUIRED | Repository name — joins to `git_pull_requests.repo_slug` |
| `pr_id` | Int64 | REQUIRED | PR database ID — joins to `git_pull_requests.pr_id` |
| `field_id` | String | REQUIRED | Machine identifier for the property (e.g. `review_depth_score`, `cycle_time_hours`) |
| `field_name` | String | REQUIRED | Human-readable label for the property (e.g. `"Review Depth Score"`) |
| `field_value_str` | String | NULLABLE | String / JSON value; NULL when the property is purely numeric |
| `field_value_int` | Int64 | NULLABLE | Integer or boolean (0/1) value; NULL when the property is not an integer |
| `field_value_float` | Float64 | NULLABLE | Fractional numeric value; NULL when the property is not a float |
| `collected_at` | DateTime64(3) | REQUIRED | When this property was collected/computed |
| `data_source` | String | DEFAULT '' | Source discriminator — joins to `git_pull_requests.data_source` |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Value column rules**: at least one of `field_value_str`, `field_value_int`, `field_value_float` must be non-NULL. Boolean flags use `field_value_int` (`0`/`1`); duration/score values use `field_value_float`; JSON results use `field_value_str`.

**Indexes**:
- `idx_pr_ext_lookup`: `(tenant_id, insight_source_id, project_key, repo_slug, pr_id, field_id, data_source)`
- `idx_pr_ext_field_id`: `(field_id)`

**Purpose**: Flexible key-value table for storing extended PR properties without modifying the core `git_pull_requests` schema. Enables addition of new analysis results (review quality metrics, AI-assisted PR detection, security analysis, complexity scores) without schema migrations.

**Common property keys**:
- `review_depth_score` — Quality/depth of code review (0.0–1.0) — value: `field_value_float`
- `review_participation_ratio` — Percentage of team members who reviewed — value: `field_value_float`
- `ai_generated_percentage` — Estimated AI-generated code in PR (0.0–1.0) — value: `field_value_float`
- `ai_assisted_pr_flag` — PR created/assisted by AI tools (0 or 1) — value: `field_value_int`
- `cycle_time_hours` — Time from first commit to merge in hours — value: `field_value_float`
- `pickup_time_hours` — Time from PR creation to first review in hours — value: `field_value_float`
- `rework_ratio` — Ratio of rework commits to total commits — value: `field_value_float`
- `approval_velocity` — Average time to approval in hours — value: `field_value_float`
- `complexity_score` — Code complexity metric — value: `field_value_float`
- `security_scan_results` — Security vulnerability scan results — value: `field_value_str` (JSON)
- `test_coverage_delta` — Change in test coverage from this PR — value: `field_value_float`
- `breaking_change_flag` — PR contains breaking changes (0 or 1) — value: `field_value_int`
- `hotfix_flag` — PR is a hotfix (0 or 1) — value: `field_value_int`
- `docs_only_flag` — PR only changes documentation (0 or 1) — value: `field_value_int`
- `draft_pr_flag` — PR was created as draft (GitHub-specific, 0 or 1) — value: `field_value_int`
- `diffstat_metadata` — Detailed file-level diff statistics — value: `field_value_str` (JSON)

**Usage example**:
```sql
-- Get review depth score (float, no cast needed)
SELECT field_value_float
FROM git_pull_requests_ext
WHERE tenant_id = '...'
  AND pr_id = 12345
  AND field_id = 'review_depth_score'
  AND data_source = 'insight_github';

-- Get cycle time for all merged PRs
SELECT pr.pr_number, pr.title, ext.field_value_float AS cycle_time_hours
FROM git_pull_requests pr
JOIN git_pull_requests_ext ext
  ON pr.tenant_id = ext.tenant_id
  AND pr.pr_id = ext.pr_id
  AND pr.data_source = ext.data_source
WHERE pr.tenant_id = '...'
  AND pr.project_key = 'MyOrg'
  AND pr.repo_slug = 'my-repo'
  AND pr.state = 'MERGED'
  AND ext.field_id = 'cycle_time_hours';

-- Find all hotfix PRs (integer flag, no cast)
SELECT pr.pr_number, pr.title, pr.created_on
FROM git_pull_requests pr
JOIN git_pull_requests_ext ext
  ON pr.tenant_id = ext.tenant_id
  AND pr.pr_id = ext.pr_id
  AND pr.data_source = ext.data_source
WHERE pr.tenant_id = '...'
  AND ext.field_id = 'hotfix_flag'
  AND ext.field_value_int = 1;

-- Average AI percentage across merged PRs
SELECT AVG(ext.field_value_float) AS avg_ai_pct
FROM git_pull_requests pr
JOIN git_pull_requests_ext ext
  ON pr.tenant_id = ext.tenant_id
  AND pr.pr_id = ext.pr_id
  AND pr.data_source = ext.data_source
WHERE pr.tenant_id = '...'
  AND pr.state = 'MERGED'
  AND ext.field_id = 'ai_generated_percentage';
```

**Design rationale**: 
- **Flexibility**: Add new PR metrics without schema changes
- **Source-specific features**: Store platform-specific properties (e.g., GitHub's `draft` flag, Bitbucket's `task_count`) without NULLs in main table
- **Computed metrics**: Store calculated metrics (review velocity, complexity) alongside raw data
- **Efficiency**: Query only needed properties via index on `field_id`
- **Versioning**: Track when each metric was computed via `collected_at`
- **Evolution**: Metrics can be recalculated or redefined without data migration

---

### `git_pull_requests_reviewers` — Review submissions and approvals

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | REQUIRED | Parent PR ID — joins to `git_pull_requests.pr_id` |
| `reviewer_name` | String | REQUIRED | Reviewer username |
| `reviewer_uuid` | String | REQUIRED | Reviewer unique identifier |
| `reviewer_email` | String | NULLABLE | Reviewer email — identity key (NULL when not available) |
| `status` | String | REQUIRED | Review status — normalized to: `APPROVED`, `UNAPPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` |
| `role` | String | REQUIRED | Reviewer role (always "REVIEWER" in current implementation) |
| `approved` | Int64 | REQUIRED | 1 if approved, 0 if not |
| `reviewed_at` | DateTime64(3) | NULLABLE | Review submission timestamp (NULL when not available) |
| `metadata` | String | REQUIRED | Review metadata as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_reviewer_lookup`: `(project_key, repo_slug, pr_id, reviewer_uuid, data_source)`

**Status normalization**:
- Bitbucket: `APPROVED`, `UNAPPROVED`
- GitHub: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` (GitHub's formal review model)
- GitLab: `APPROVED`, `UNAPPROVED` (approval-only model)

**Note**: GitHub's review model is more granular. The `metadata` field preserves source-specific details for platform-specific analytics.

---

### `git_pull_requests_comments`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | REQUIRED | Parent PR ID |
| `comment_id` | Int64 | REQUIRED | Comment unique ID from API |
| `content` | String | REQUIRED | Comment text/body (Markdown supported) |
| `author_name` | String | REQUIRED | Comment author username |
| `author_uuid` | String | NULLABLE | Author unique identifier |
| `author_email` | String | NULLABLE | Author email — identity key |
| `created_at` | DateTime64(3) | REQUIRED | Comment creation timestamp |
| `updated_at` | DateTime64(3) | REQUIRED | Last update timestamp |
| `state` | String | NULLABLE | Thread state (Bitbucket: `OPEN`/`RESOLVED`, GitHub: NULL) |
| `severity` | String | NULLABLE | Comment severity (Bitbucket: `NORMAL`/`BLOCKER`, GitHub: NULL) |
| `thread_resolved` | Int64 | NULLABLE | 1 if thread resolved (Bitbucket only) |
| `file_path` | String | NULLABLE | File path for inline code review comments (NULL for general comments) |
| `line_number` | Int64 | NULLABLE | Line number for inline comments (NULL for general comments) |
| `metadata` | String | REQUIRED | Comment metadata as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_comment_lookup`: `(project_key, repo_slug, pr_id, comment_id, data_source)`

**Comment types**:
- **General comments**: Discussion on the PR as a whole (`file_path` and `line_number` are NULL)
- **Inline comments**: Code review comments on specific lines (`file_path` and `line_number` populated)

---

### `git_pull_requests_commits`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | REQUIRED | Parent PR ID |
| `commit_hash` | String | REQUIRED | Commit SHA — joins to `git_commits.commit_hash` |
| `commit_order` | Int64 | REQUIRED | Order of commit within PR (0-indexed) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_pr_commit_lookup`: `(project_key, repo_slug, pr_id, commit_hash, data_source)`

**Purpose**: Junction table linking PRs to commits. A commit may appear in multiple PRs if cherry-picked or merged across branches. This table preserves the many-to-many relationship.

---

### `git_tickets` — Ticket references extracted from PRs and commits

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `external_ticket_id` | String | REQUIRED | Ticket ID extracted from text, e.g. `PROJ-123`, `#456` |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | NULLABLE | Associated PR (NULL if from commit) |
| `commit_hash` | String | NULLABLE | Associated commit (NULL if from PR) |
| `ticket_source` | String | REQUIRED | Source of ticket reference: `PR_TITLE`, `PR_DESCRIPTION`, `COMMIT_MESSAGE` |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_ticket_lookup`: `(external_ticket_id, project_key, repo_slug, data_source)`

**Purpose**: Links code activity back to task tracker items (Jira, Linear, etc.) without requiring real-time joins. Enables queries like "show all PRs related to PROJ-123" or "calculate cycle time from ticket creation to PR merge."

**Extraction patterns**: Common patterns include Jira keys (`[A-Z]+-[0-9]+`), GitHub issue numbers (`#[0-9]+`), and custom formats configurable per organization.

---

### `git_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `tenant_id` | UUID | REQUIRED | Tenant identifier — injected by framework |
| `insight_source_id` | String | REQUIRED | Source instance identifier |
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp (NULL if still running) |
| `status` | String | REQUIRED | Run status: `running`, `completed`, `failed` |
| `repos_processed` | Int64 | NULLABLE | Number of repositories processed |
| `commits_collected` | Int64 | NULLABLE | Number of commits collected |
| `prs_collected` | Int64 | NULLABLE | Number of PRs collected |
| `api_calls` | Int64 | NULLABLE | Total API calls made |
| `errors` | Int64 | NULLABLE | Number of errors encountered |
| `settings` | String | NULLABLE | Collection configuration as JSON (org, repos, lookback period) |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_run_lookup`: `(run_id, data_source)`
- `idx_run_started`: `(started_at)`

**Purpose**: Monitoring and debugging table — not an analytics source. Tracks connector execution health, performance, and error rates.

---

## Data Source Support

### Bitbucket Server

**API**: REST API v1.0

**Data source identifier**: `insight_bitbucket_server`

**Authentication**: HTTP Basic Auth or Personal Access Token

**Key endpoints**:
- Projects: `/rest/api/1.0/projects`
- Repositories: `/rest/api/1.0/projects/{project}/repos`
- Commits: `/rest/api/1.0/projects/{project}/repos/{repo}/commits`
- PRs: `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests`

**Limitations**:
- No repository creation date in API
- No primary language detection
- Email addresses may be corporate-specific format
- Review model is simpler (approved/unapproved only)

---

### GitHub

**API**: REST API v3 + GraphQL API v4

**Data source identifier**: `insight_github`

**Authentication**: GitHub App installation token or Personal Access Token (PAT)

**Key endpoints**:
- REST repositories: `/repos/{owner}/{repo}`
- REST commits: `/repos/{owner}/{repo}/commits`
- REST PRs: `/repos/{owner}/{repo}/pulls`
- GraphQL: `repository` query with nested data (100x more efficient)

**Advantages**:
- GraphQL allows bulk fetching (100 commits per call vs 1 in REST)
- Rich metadata (language, size, timestamps)
- Formal review model with multiple states
- Email addresses widely available

**Limitations**:
- Rate limiting stricter than Bitbucket
- Privacy settings may mask emails
- Draft PR concept not in Bitbucket/GitLab

---

### GitLab

**API**: REST API v4 + GraphQL (experimental)

**Data source identifier**: `insight_gitlab`

**Authentication**: Personal Access Token or OAuth2

**Key endpoints**:
- Projects: `/api/v4/projects`
- Commits: `/api/v4/projects/{id}/repository/commits`
- Merge Requests: `/api/v4/projects/{id}/merge_requests`

**Terminology differences**:
- "Merge Request" instead of "Pull Request"
- "Project" instead of "Repository"
- Approval model similar to Bitbucket

---

## Identity Resolution

**Primary identity key**: `author_email` from commits and `reviewer_email` from reviews

**Fallback identifiers**: `author_name`, `author_uuid` (source-specific username and ID)

**Resolution process**:
1. Extract email from `git_commits.author_email` and `git_pull_requests_reviewers.reviewer_email`
2. Normalize email (lowercase, trim whitespace)
3. Map to canonical `person_id` via Identity Manager in Gold step 2
4. If email absent/masked, attempt resolution by `author_name` or `author_uuid` with source context
5. Create new `person_id` if no match found

**Cross-source matching**: Same person may have different usernames across platforms but same email. Email-based resolution ensures they're identified as one person in analytics.

**Deduplication**: `commit_hash` is globally unique. If same commit appears from multiple sources (mirrored repos), use `COUNT(DISTINCT commit_hash)` in queries to avoid double-counting work.

---

## Silver / Gold Mappings

| Silver table | Gold target | Status |
|-------------|--------------|--------|
| `git_repositories` | *(reference table)* | No unified stream — used for filtering and metadata |
| `git_repositories_ext` | *(aggregated metrics)* | Used for repository analytics dashboards and health scoring |
| `git_repository_branches` | *(reference table)* | No unified stream — used for incremental sync |
| `git_commits` | `class_commits` | Planned — stream not yet defined |
| `git_commits_ext` | *(enrichment data)* | Merged into `class_commits` during Silver transformation |
| `git_pull_requests` | `class_pr_activity` | Planned — stream not yet defined |
| `git_pull_requests_ext` | *(enrichment data)* | Merged into `class_pr_activity` during Gold transformation |
| `git_tickets` | Cross-domain join → `class_task_tracker_activities.task_id` | Planned |
| `git_commit_files` | *(granular detail)* | Available — no unified stream defined yet |
| `git_commits_files_ext` | *(enrichment data)* | Merged into `class_commits` during Silver transformation alongside `git_commits_ext` |
| `git_pull_requests_reviewers` | *(review analytics)* | Available — aggregated into PR-level metrics |
| `git_pull_requests_comments` | *(review analytics)* | Available — aggregated into PR-level metrics |
| `git_pull_requests_commits` | *(junction)* | Used internally for PR↔commit linkage |

**Planned Gold streams**:
- `class_commits`: Deduplicated commits with resolved `person_id`, language breakdown, and AI detection flags
- `class_pr_activity`: PR lifecycle events with review depth metrics and cycle time calculations

**Gold metrics**:
- Commit-level: lines of code per author, AI percentage trends, commit frequency, language distribution
- PR-level: cycle time (creation to merge), review depth (comments per PR), approval time, merge rate
- Team-level: throughput (commits/PRs per week), collaboration patterns (review participation), quality indicators (rework ratio)

---

## Open Questions

### OQ-GIT-1: Field naming standardization across sources

Current implementation uses `project_key` + `repo_slug` (Bitbucket terminology) as the standard repository identifier. However:
- GitHub uses `owner` + `name`
- GitLab uses `namespace` + `path`

**Question**: Should we maintain Bitbucket naming in the unified schema, or adopt neutral terms like `org_key` + `repo_name`?

**Impact**: Existing queries and transformations may need updates if field names change.

---

### OQ-GIT-2: Handling source-specific features

Some features are platform-specific:
- GitHub: `draft` PRs, formal review states (`CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`)
- Bitbucket: `task_count`, comment `severity` (`BLOCKER`)
- GitLab: Approval rules, merge request approvals

**Current approach**: Store in `metadata` JSON column, expose in Silver schema only if widely supported

**Question**: Should we add nullable columns for common source-specific features (e.g., `is_draft`, `task_count`) even if they're NULL for some sources?

**Tradeoff**: More columns = easier querying but more schema complexity

---

### OQ-GIT-3: Deduplication strategy for mirrored repositories

When a repository is mirrored across GitHub and Bitbucket, the same `commit_hash` appears twice with different `data_source` values.

**Current approach**: Both records stored in `git_commits`, analytics must `COUNT(DISTINCT commit_hash)`

**Alternatives**:
1. Deduplicate at ingestion — only store first-seen source
2. Add `is_primary_source` flag — mark one source as canonical
3. Keep both records — require DISTINCT in queries (current)

**Question**: Which approach best serves analytics needs?

**Consideration**: Different sources may have different metadata quality (e.g., GitHub has better language detection). Keeping both records allows choosing best metadata at Gold layer.

---


# GitHub Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 1 (GitHub)

Standalone specification for the GitHub (Version Control) connector. Expands Source 1 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`github_repositories`](#githubrepositories)
  - [`github_branches`](#githubbranches)
  - [`github_commits`](#githubcommits)
  - [`github_commit_files` — Per-file line changes](#githubcommitfiles-per-file-line-changes)
  - [`github_pull_requests`](#githubpullrequests)
  - [`github_pull_request_reviews` — Formal review submissions](#githubpullrequestreviews-formal-review-submissions)
  - [`github_pull_request_comments`](#githubpullrequestcomments)
  - [`github_pull_request_commits`](#githubpullrequestcommits)
  - [`github_ticket_refs` — Ticket references extracted from PRs and commits](#githubticketrefs-ticket-references-extracted-from-prs-and-commits)
  - [`github_collection_runs` — Connector execution log](#githubcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-GH-1: Git deduplication across sources](#oq-gh-1-git-deduplication-across-sources)
  - [OQ-GH-2: Git streams layer relationship to Bronze](#oq-gh-2-git-streams-layer-relationship-to-bronze)
  - [OQ-GH-3: PR/commit field naming inconsistency](#oq-gh-3-prcommit-field-naming-inconsistency)
  - [OQ-GH-4: Bronze schema — extra tables in stream spec](#oq-gh-4-bronze-schema-extra-tables-in-stream-spec)

<!-- /toc -->

---

## Overview

**API**: GitHub REST v3 + GraphQL v4

**Category**: Version Control

**Authentication**: GitHub App installation token or Personal Access Token (PAT)

**Identity**: `author_email` (from `github_commits`) + `author_login` (GitHub username) — resolved to canonical `person_id` via Identity Manager. Email takes precedence; login is a fallback when email is absent (GitHub masks emails for privacy).

**Field naming**: PascalCase and snake_case mixed — source field names from GitHub API preserved as-is at Bronze level.

**Why multiple tables**: Git data is inherently relational — a commit has many files (1:N), a PR has many reviewers, comments, and commits (all 1:N). Merging into a single flat table would require either denormalization (repeating PR metadata on every file row) or loss of the relational model. Each table stores one entity type with its own primary key.

> **Note**: GitHub's formal review model (`github_pull_request_reviews`) distinguishes between `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, and `DISMISSED` states. Bitbucket and GitLab do not have an equivalent — this table is GitHub-specific.

---

## Bronze Tables

### `github_repositories`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Organization or user login |
| `repo_name` | String | Repository name |
| `full_name` | String | Full path, e.g. `org/repo` |
| `description` | String | Repository description |
| `is_private` | Int | 1 if private |
| `language` | String | Primary programming language |
| `size` | Int | Repository size in KB |
| `created_at` | DateTime | Repository creation date |
| `updated_at` | DateTime | Last update |
| `pushed_at` | DateTime | Date of most recent push |
| `default_branch` | String | Default branch name |
| `is_empty` | Int | 1 if no commits |
| `metadata` | String (JSON) | Full API response |

---

### `github_branches`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Repository owner |
| `repo_name` | String | Repository name |
| `branch_name` | String | Branch name |
| `is_default` | Int | 1 if default branch |
| `last_commit_hash` | String | Last collected commit — cursor for incremental sync |
| `last_commit_date` | DateTime | Date of last commit |
| `last_checked_at` | DateTime | When this branch was last checked |

---

### `github_commits`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Repository owner |
| `repo_name` | String | Repository name |
| `commit_hash` | String | Git SHA-1 (40 chars) — primary key |
| `branch` | String | Branch where commit was found |
| `author_name` | String | Commit author name |
| `author_email` | String | Author email — primary identity key for cross-system resolution |
| `author_login` | String | GitHub username of author (if matched) |
| `committer_name` | String | Committer name |
| `committer_email` | String | Committer email |
| `message` | String | Commit message |
| `date` | DateTime | Commit timestamp |
| `parents` | String (JSON) | Parent commit hashes — len > 1 = merge commit |
| `files_changed` | Int | Number of files modified |
| `lines_added` | Int | Total lines added |
| `lines_removed` | Int | Total lines removed |
| `is_merge_commit` | Int | 1 if merge commit |
| `language_breakdown` | String (JSON) | Lines per language, e.g. `{"TypeScript": 120}` |
| `ai_percentage` | Float | AI-generated code estimate (0.0–1.0) |
| `ai_thirdparty_flag` | Int | 1 if AI-detected third-party code |
| `scancode_thirdparty_flag` | Int | 1 if license scanner detected third-party |
| `metadata` | String (JSON) | Full API response |

---

### `github_commit_files` — Per-file line changes

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Repository owner |
| `repo_name` | String | Repository name |
| `commit_hash` | String | Parent commit — joins to `github_commits.commit_hash` |
| `file_path` | String | Full file path |
| `file_extension` | String | File extension |
| `lines_added` | Int | Lines added in this file |
| `lines_removed` | Int | Lines removed in this file |
| `ai_thirdparty_flag` | Int | AI-detected third-party code |
| `scancode_thirdparty_flag` | Int | License scanner detected third-party |
| `scancode_metadata` | String (JSON) | License and copyright info |

---

### `github_pull_requests`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Repository owner |
| `repo_name` | String | Repository name |
| `pr_number` | Int | PR number — unique per repo |
| `node_id` | String | GraphQL global node ID |
| `title` | String | PR title |
| `body` | String | PR description |
| `state` | String | `open` / `closed` / `merged` |
| `draft` | Int | 1 if draft PR |
| `author_login` | String | PR author GitHub login |
| `author_email` | String | Author email (from commit) |
| `head_branch` | String | Source branch |
| `base_branch` | String | Target branch |
| `created_at` | DateTime | PR creation time |
| `updated_at` | DateTime | Last update |
| `merged_at` | DateTime | Merge time (NULL if not merged) |
| `closed_at` | DateTime | Close time |
| `merged_by_login` | String | GitHub login of who merged |
| `merge_commit_hash` | String | Hash of merge commit |
| `files_changed` | Int | Files modified |
| `lines_added` | Int | Lines added |
| `lines_removed` | Int | Lines removed |
| `commit_count` | Int | Number of commits in PR |
| `comment_count` | Int | Number of general comments |
| `review_comment_count` | Int | Number of inline review comments |
| `duration_seconds` | Int | Time from creation to close |
| `ticket_refs` | String (JSON) | Extracted issue / ticket IDs |

---

### `github_pull_request_reviews` — Formal review submissions

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Repository owner |
| `repo_name` | String | Repository name |
| `pr_number` | Int | Parent PR — joins to `github_pull_requests.pr_number` |
| `review_id` | Int | Review unique ID |
| `reviewer_login` | String | Reviewer GitHub login |
| `reviewer_email` | String | Reviewer email — identity key |
| `state` | String | `APPROVED` / `CHANGES_REQUESTED` / `COMMENTED` / `DISMISSED` |
| `submitted_at` | DateTime | Review submission time |

GitHub's formal review model distinguishes review state from plain comments. This table is GitHub-specific — Bitbucket uses `bitbucket_pull_request_reviewers`; GitLab uses `gitlab_mr_approvals` (approval only).

---

### `github_pull_request_comments`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Repository owner |
| `repo_name` | String | Repository name |
| `pr_number` | Int | Parent PR |
| `comment_id` | Int | Comment unique ID |
| `comment_type` | String | `issue_comment` (general) / `review_comment` (inline on file) |
| `content` | String | Comment text (Markdown) |
| `author_login` | String | Comment author login |
| `author_email` | String | Author email — identity key |
| `created_at` | DateTime | Creation timestamp |
| `updated_at` | DateTime | Last update timestamp |
| `file_path` | String | File path for inline comments (NULL for general) |
| `line_number` | Int | Line number for inline comments (NULL for general) |
| `in_reply_to_id` | Int | Parent comment ID for threaded replies |

---

### `github_pull_request_commits`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Repository owner |
| `repo_name` | String | Repository name |
| `pr_number` | Int | Parent PR |
| `commit_hash` | String | Commit SHA — joins to `github_commits.commit_hash` |
| `commit_order` | Int | Order within PR (0-indexed) |

Links commits to their parent PR. A commit may appear in multiple branches / PRs — this junction table preserves the association.

---

### `github_ticket_refs` — Ticket references extracted from PRs and commits

| Field | Type | Description |
|-------|------|-------------|
| `external_ticket_id` | String | Ticket ID, e.g. `PROJ-123` |
| `owner` | String | Repository owner |
| `repo_name` | String | Repository name |
| `pr_number` | Int | Associated PR (NULL if from commit) |
| `commit_hash` | String | Associated commit (NULL if from PR) |

Links code activity back to task tracker items without requiring real-time joins across systems.

---

### `github_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier |
| `started_at` | DateTime | Run start time |
| `completed_at` | DateTime | Run end time |
| `status` | String | `running` / `completed` / `failed` |
| `repos_processed` | Int | Repositories processed |
| `commits_collected` | Int | Commits collected |
| `prs_collected` | Int | PRs collected |
| `api_calls` | Int | API calls made |
| `errors` | Int | Errors encountered |
| `settings` | String (JSON) | Collection configuration (org, repos, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

GitHub uses two identity fields for commits: `author_email` and `author_login`. Email is the primary cross-system identity key — it is mapped to canonical `person_id` via the Identity Manager in Silver step 2.

`author_login` (GitHub username) is a Bitbucket-incompatible identifier — it cannot be used for cross-source resolution. It is used as a fallback when email is absent (GitHub masks emails for some accounts).

PR reviews and comments also carry `reviewer_email` / `author_email` — resolved to `person_id` in the same step.

`github_commits.commit_hash` (40-char SHA-1) is used to deduplicate commits across Bitbucket and GitLab mirrors (see OQ-GH-1).

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `github_commits` | `class_commits` | Planned — stream not yet defined |
| `github_pull_requests` | `class_pr_activity` | Planned — stream not yet defined |
| `github_ticket_refs` | Used for `class_task_tracker` cross-reference | Planned |
| `github_repositories` | *(reference table)* | No unified stream — used for filtering |
| `github_branches` | *(reference table)* | No unified stream — used for incremental sync |
| `github_commit_files` | *(granular detail)* | Available — no unified stream defined yet |
| `github_pull_request_reviews` | *(review analytics)* | Available — no unified stream defined yet |
| `github_pull_request_comments` | *(review analytics)* | Available — no unified stream defined yet |
| `github_pull_request_commits` | *(junction)* | Used internally for PR↔commit linkage |

**Gold**: commit-level Gold metrics (lines of code, AI percentage trends, throughput per author) and PR-level Gold metrics (cycle time, review depth, merge rate) will be derived from the `class_commits` and `class_pr_activity` Silver streams once defined.

---

## Open Questions

### OQ-GH-1: Git deduplication across sources

A company may mirror the same repository from GitHub to Bitbucket (or GitLab). The same `commit_hash` will arrive from two separate Bronze sources.

- Does `class_commits` deduplicate by `commit_hash` globally, regardless of source?
- If yes: which source wins when metadata differs (e.g. `author_email` present in one, absent in another)?
- If no: both rows exist in Silver with different `source` values — aggregations must `COUNT(DISTINCT commit_hash)`.

See also: `CONNECTORS_REFERENCE.md` OQ-1.

### OQ-GH-2: Git streams layer relationship to Bronze

The `streams/raw_git/` directory (PR #3) defines a git streams layer. The relationship to Bronze tables in this spec is unclear.

- Is `streams/raw_git/` an intermediate layer between raw API responses and Bronze?
- Or does it define Bronze schemas directly (in which case this spec is the authoritative duplicate)?

See also: `CONNECTORS_REFERENCE.md` OQ-9.

### OQ-GH-3: PR/commit field naming inconsistency

`github_commits` uses `owner` + `repo_name` while other tables in the git category may use `project_key` + `repo_slug` (Bitbucket naming convention).

- Should all git Bronze tables use a unified namespace field pair?
- What is the canonical cross-source field name for the repository namespace?

See also: `CONNECTORS_REFERENCE.md` OQ-10.

### OQ-GH-4: Bronze schema — extra tables in stream spec

PR #3 may define additional tables (e.g. unified git tables with a `data_source` discriminator column) not present in this per-source spec.

- Are per-source tables (`github_commits`, `bitbucket_commits`, `gitlab_commits`) the canonical Bronze layer?
- Or is there a unified `git_commits` table with a `data_source` column that replaces per-source tables?

See also: `CONNECTORS_REFERENCE.md` OQ-8.

# Bitbucket Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 2 (Bitbucket)

Standalone specification for the Bitbucket (Version Control) connector. Expands Source 2 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`bitbucket_repositories`](#bitbucketrepositories)
  - [`bitbucket_branches`](#bitbucketbranches)
  - [`bitbucket_commits`](#bitbucketcommits)
  - [`bitbucket_commit_files` — Per-file line changes](#bitbucketcommitfiles-per-file-line-changes)
  - [`bitbucket_pull_requests`](#bitbucketpullrequests)
  - [`bitbucket_pull_request_reviewers` — Reviewer list with status](#bitbucketpullrequestreviewers-reviewer-list-with-status)
  - [`bitbucket_pull_request_comments`](#bitbucketpullrequestcomments)
  - [`bitbucket_pull_request_commits`](#bitbucketpullrequestcommits)
  - [`bitbucket_ticket_refs` — Ticket references extracted from PRs and commits](#bitbucketticketrefs-ticket-references-extracted-from-prs-and-commits)
  - [`bitbucket_collection_runs` — Connector execution log](#bitbucketcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-BB-1: `uuid` vs `account_id` as the canonical Bitbucket user identifier](#oq-bb-1-uuid-vs-accountid-as-the-canonical-bitbucket-user-identifier)
  - [OQ-BB-2: Cross-source deduplication with GitHub/GitLab mirrors](#oq-bb-2-cross-source-deduplication-with-githubgitlab-mirrors)

<!-- /toc -->

---

## Overview

**API**: Bitbucket REST v1/v2

**Category**: Version Control

**Authentication**: OAuth 2.0 (App passwords or Workspace access tokens)

**Identity**: `author_email` (from `bitbucket_commits`) — resolved to canonical `person_id` via Identity Manager. Bitbucket users are identified internally by `uuid` and `account_id`; email takes precedence for cross-system resolution.

**Field naming**: snake_case — Bitbucket API uses snake_case; preserved as-is at Bronze level.

**Why multiple tables**: Same 1:N relational structure as GitHub — a commit has many files, a PR has many reviewers, comments, and commits. See `github.md` for the rationale; Bitbucket follows the same pattern with structural differences noted below.

**Key differences from GitHub:**

| Aspect | GitHub | Bitbucket |
|--------|--------|-----------|
| User identity | `login` (username) | `uuid` + `account_id` |
| Namespace field | `owner` | `workspace` |
| PR review model | Formal reviews with `state` (`APPROVED` / `CHANGES_REQUESTED` / etc.) | Simple reviewer list with `status` (`APPROVED` / `UNAPPROVED` / `NEEDS_WORK`) |
| Comment severity | — | `severity`: `NORMAL` / `BLOCKER` (blocking comments must be resolved before merge) |
| PR state values | `open` / `closed` / `merged` | `OPEN` / `MERGED` / `DECLINED` |
| Draft PRs | `draft` boolean | Not supported |
| Merged by | `merged_by_login` | Not returned by API |
| Review comments | `comment_type` distinguishes general vs inline | All comments are the same kind |

---

## Bronze Tables

### `bitbucket_repositories`

| Field | Type | Description |
|-------|------|-------------|
| `workspace` | String | Bitbucket workspace slug (replaces `owner`) |
| `repo_name` | String | Repository slug |
| `full_name` | String | Full path, e.g. `workspace/repo` |
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

### `bitbucket_branches`

| Field | Type | Description |
|-------|------|-------------|
| `workspace` | String | Bitbucket workspace slug |
| `repo_name` | String | Repository slug |
| `branch_name` | String | Branch name |
| `is_default` | Int | 1 if default branch |
| `last_commit_hash` | String | Last collected commit — cursor for incremental sync |
| `last_commit_date` | DateTime | Date of last commit |
| `last_checked_at` | DateTime | When this branch was last checked |

---

### `bitbucket_commits`

| Field | Type | Description |
|-------|------|-------------|
| `workspace` | String | Bitbucket workspace slug |
| `repo_name` | String | Repository slug |
| `commit_hash` | String | Git SHA-1 (40 chars) — primary key |
| `branch` | String | Branch where commit was found |
| `author_name` | String | Commit author name |
| `author_email` | String | Author email — primary identity key |
| `author_uuid` | String | Bitbucket user UUID of the author (if matched) |
| `author_account_id` | String | Atlassian account ID of the author (if matched) |
| `committer_name` | String | Committer name |
| `committer_email` | String | Committer email |
| `message` | String | Commit message |
| `date` | DateTime | Commit timestamp |
| `parents` | String (JSON) | Parent commit hashes |
| `files_changed` | Int | Number of files modified |
| `lines_added` | Int | Total lines added |
| `lines_removed` | Int | Total lines removed |
| `is_merge_commit` | Int | 1 if merge commit |
| `language_breakdown` | String (JSON) | Lines per language |
| `ai_percentage` | Float | AI-generated code estimate (0.0–1.0) |
| `ai_thirdparty_flag` | Int | 1 if AI-detected third-party code |
| `scancode_thirdparty_flag` | Int | 1 if license scanner detected third-party |
| `metadata` | String (JSON) | Full API response |

---

### `bitbucket_commit_files` — Per-file line changes

| Field | Type | Description |
|-------|------|-------------|
| `workspace` | String | Bitbucket workspace slug |
| `repo_name` | String | Repository slug |
| `commit_hash` | String | Parent commit |
| `file_path` | String | Full file path |
| `file_extension` | String | File extension |
| `lines_added` | Int | Lines added in this file |
| `lines_removed` | Int | Lines removed in this file |
| `ai_thirdparty_flag` | Int | AI-detected third-party code |
| `scancode_thirdparty_flag` | Int | License scanner detected third-party |
| `scancode_metadata` | String (JSON) | License and copyright info |

---

### `bitbucket_pull_requests`

| Field | Type | Description |
|-------|------|-------------|
| `workspace` | String | Bitbucket workspace slug |
| `repo_name` | String | Repository slug |
| `pr_number` | Int | PR number — unique per repo |
| `title` | String | PR title |
| `body` | String | PR description |
| `state` | String | `OPEN` / `MERGED` / `DECLINED` |
| `author_uuid` | String | PR author Bitbucket UUID |
| `author_account_id` | String | PR author Atlassian account ID |
| `author_email` | String | Author email |
| `head_branch` | String | Source branch |
| `base_branch` | String | Target branch |
| `created_at` | DateTime | PR creation time |
| `updated_at` | DateTime | Last update |
| `merged_at` | DateTime | Merge time (NULL if not merged) |
| `closed_at` | DateTime | Close time |
| `files_changed` | Int | Files modified |
| `lines_added` | Int | Lines added |
| `lines_removed` | Int | Lines removed |
| `commit_count` | Int | Number of commits in PR |
| `comment_count` | Int | Number of comments |
| `duration_seconds` | Int | Time from creation to close |
| `ticket_refs` | String (JSON) | Extracted issue / ticket IDs |

Note: `draft` and `merged_by_login` are not supported by the Bitbucket API.

---

### `bitbucket_pull_request_reviewers` — Reviewer list with status

| Field | Type | Description |
|-------|------|-------------|
| `workspace` | String | Bitbucket workspace slug |
| `repo_name` | String | Repository slug |
| `pr_number` | Int | Parent PR |
| `reviewer_uuid` | String | Reviewer Bitbucket UUID |
| `reviewer_account_id` | String | Reviewer Atlassian account ID |
| `reviewer_email` | String | Reviewer email — identity key |
| `status` | String | `APPROVED` / `UNAPPROVED` / `NEEDS_WORK` |

Replaces `github_pull_request_reviews`. Bitbucket has no separate review state transitions — only current reviewer status.

---

### `bitbucket_pull_request_comments`

| Field | Type | Description |
|-------|------|-------------|
| `workspace` | String | Bitbucket workspace slug |
| `repo_name` | String | Repository slug |
| `pr_number` | Int | Parent PR |
| `comment_id` | Int | Comment unique ID |
| `content` | String | Comment text (Markdown) |
| `author_uuid` | String | Comment author UUID |
| `author_email` | String | Author email — identity key |
| `severity` | String | `NORMAL` / `BLOCKER` — BLOCKER comments must be resolved before merge |
| `created_at` | DateTime | Creation timestamp |
| `updated_at` | DateTime | Last update timestamp |
| `file_path` | String | File path for inline comments (NULL for general) |
| `line_number` | Int | Line number for inline comments (NULL for general) |

Note: `comment_type` and `in_reply_to_id` are absent from the Bitbucket API; `severity` is Bitbucket-specific.

---

### `bitbucket_pull_request_commits`

| Field | Type | Description |
|-------|------|-------------|
| `workspace` | String | Bitbucket workspace slug |
| `repo_name` | String | Repository slug |
| `pr_number` | Int | Parent PR |
| `commit_hash` | String | Commit SHA |
| `commit_order` | Int | Order within PR (0-indexed) |

---

### `bitbucket_ticket_refs` — Ticket references extracted from PRs and commits

| Field | Type | Description |
|-------|------|-------------|
| `external_ticket_id` | String | Ticket ID, e.g. `PROJ-123` |
| `workspace` | String | Bitbucket workspace slug |
| `repo_name` | String | Repository slug |
| `pr_number` | Int | Associated PR (NULL if from commit) |
| `commit_hash` | String | Associated commit (NULL if from PR) |

---

### `bitbucket_collection_runs` — Connector execution log

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
| `settings` | String (JSON) | Collection configuration (workspace, repos, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`author_email` in `bitbucket_commits` is the primary identity key — mapped to canonical `person_id` via Identity Manager in Silver step 2.

Bitbucket's internal identifiers — `uuid` and `account_id` (Atlassian account ID) — are not used for cross-system resolution. Email takes precedence. When email is absent, `uuid` may be used as a fallback if a Bitbucket-specific email lookup is implemented.

`reviewer_email` in `bitbucket_pull_request_reviewers` and `author_email` in `bitbucket_pull_request_comments` are resolved to `person_id` in the same Silver step 2.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `bitbucket_commits` | `class_commits` | Planned — stream not yet defined |
| `bitbucket_pull_requests` | `class_pr_activity` | Planned — stream not yet defined |
| `bitbucket_ticket_refs` | Used for `class_task_tracker` cross-reference | Planned |
| `bitbucket_repositories` | *(reference table)* | No unified stream |
| `bitbucket_branches` | *(reference table)* | No unified stream |
| `bitbucket_commit_files` | *(granular detail)* | Available — no unified stream defined yet |
| `bitbucket_pull_request_reviewers` | *(review analytics)* | Available — no unified stream defined yet |
| `bitbucket_pull_request_comments` | *(review analytics)* | Available — no unified stream defined yet |

**Gold**: Same as GitHub — commit-level and PR-level Gold metrics derived from unified `class_commits` and `class_pr_activity` streams once defined.

---

## Open Questions

### OQ-BB-1: `uuid` vs `account_id` as the canonical Bitbucket user identifier

Bitbucket exposes both `uuid` (Bitbucket-native) and `account_id` (Atlassian platform ID, shared across Jira and Confluence). When email is unavailable, which identifier should be used as the identity fallback?

- `account_id` is more useful for Jira cross-referencing (same Atlassian platform)
- `uuid` is the Bitbucket-native key used in the REST API

### OQ-BB-2: Cross-source deduplication with GitHub/GitLab mirrors

Bitbucket repositories may be mirrors of GitHub repositories. The same `commit_hash` will arrive from both connectors.

- Same question as OQ-GH-1 — see `github.md` for full discussion.
- Decision applies equally to Bitbucket commits appearing in `class_commits`.

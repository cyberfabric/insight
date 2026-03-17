# GitLab Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 3 (GitLab)

Standalone specification for the GitLab (Version Control) connector. Expands Source 3 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`gitlab_repositories`](#gitlabrepositories)
  - [`gitlab_branches`](#gitlabbranches)
  - [`gitlab_commits`](#gitlabcommits)
  - [`gitlab_num_stat` — Per-file line changes (GitLab-specific)](#gitlabnumstat-per-file-line-changes-gitlab-specific)
  - [`gitlab_files` — File path lookup (GitLab-specific)](#gitlabfiles-file-path-lookup-gitlab-specific)
  - [`gitlab_merge_requests`](#gitlabmergerequests)
  - [`gitlab_mr_approvals` — MR approvals (GitLab-specific)](#gitlabmrapprovals-mr-approvals-gitlab-specific)
  - [`gitlab_pull_request_comments`](#gitlabpullrequestcomments)
  - [`gitlab_pull_request_commits`](#gitlabpullrequestcommits)
  - [`gitlab_ticket_refs` — Ticket references extracted from MRs and commits](#gitlabticketrefs-ticket-references-extracted-from-mrs-and-commits)
  - [`gitlab_collection_runs` — Connector execution log](#gitlabcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-GL-1: `mr_iid` vs `mr_id` as the primary MR identifier](#oq-gl-1-mriid-vs-mrid-as-the-primary-mr-identifier)
  - [OQ-GL-2: `gitlab_num_stat` vs inline file stats in commits](#oq-gl-2-gitlabnumstat-vs-inline-file-stats-in-commits)

<!-- /toc -->

---

## Overview

**API**: GitLab REST API v4

**Category**: Version Control

**Authentication**: Personal Access Token or OAuth 2.0 (GitLab App)

**Identity**: `author_email` (from `gitlab_commits`) + `username` — resolved to canonical `person_id` via Identity Manager. Email takes precedence.

**Field naming**: snake_case — GitLab API uses Python-style snake_case; preserved as-is at Bronze level.

**Why multiple tables**: Same 1:N relational structure as GitHub (commits → files, MR → approvals, comments, commits). GitLab-specific additions: `gitlab_num_stat` (separate file-stats table instead of inline) and `gitlab_files` (path lookup).

**Key differences from GitHub:**

| Aspect | GitHub | GitLab |
|--------|--------|--------|
| PR terminology | Pull Request | Merge Request (MR) |
| PR identifier | `pr_number` (per-repo) | `mr_iid` (per-project) + `mr_id` (global) |
| User identity | `login` | `username` + numeric `id` |
| Commit file stats | Inline in `github_commits` + `github_commit_files` | Separate `gitlab_num_stat` table; file paths in `gitlab_files` lookup |
| Review model | `github_pull_request_reviews` with states | `gitlab_mr_approvals` — approval only, no `CHANGES_REQUESTED` |
| MR state values | `open` / `closed` / `merged` | `opened` / `closed` / `merged` / `locked` |
| Draft MRs | `draft` boolean | `work_in_progress` boolean (legacy `WIP:` title prefix) |

---

## Bronze Tables

### `gitlab_repositories`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Namespace (group or user) |
| `repo_name` | String | Project slug |
| `full_name` | String | Full path, e.g. `group/repo` |
| `description` | String | Project description |
| `is_private` | Int | 1 if private |
| `language` | String | Primary programming language |
| `size` | Int | Repository size in KB |
| `created_at` | DateTime | Project creation date |
| `updated_at` | DateTime | Last update |
| `pushed_at` | DateTime | Date of most recent push |
| `default_branch` | String | Default branch name |
| `is_empty` | Int | 1 if no commits |
| `metadata` | String (JSON) | Full API response |

---

### `gitlab_branches`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Namespace |
| `repo_name` | String | Project slug |
| `branch_name` | String | Branch name |
| `is_default` | Int | 1 if default branch |
| `last_commit_hash` | String | Last collected commit — cursor for incremental sync |
| `last_commit_date` | DateTime | Date of last commit |
| `last_checked_at` | DateTime | When this branch was last checked |

---

### `gitlab_commits`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Namespace |
| `repo_name` | String | Project slug |
| `commit_hash` | String | Git SHA-1 (40 chars) — primary key |
| `branch` | String | Branch where commit was found |
| `author_name` | String | Commit author name |
| `author_email` | String | Author email — primary identity key |
| `author_username` | String | GitLab username of author (if matched) |
| `committer_name` | String | Committer name |
| `committer_email` | String | Committer email |
| `message` | String | Commit message |
| `date` | DateTime | Commit timestamp |
| `parents` | String (JSON) | Parent commit hashes |
| `files_changed` | Int | Number of files modified (summary count) |
| `lines_added` | Int | Total lines added (summary) |
| `lines_removed` | Int | Total lines removed (summary) |
| `is_merge_commit` | Int | 1 if merge commit |
| `language_breakdown` | String (JSON) | Lines per language |
| `ai_percentage` | Float | AI-generated code estimate (0.0–1.0) |
| `ai_thirdparty_flag` | Int | 1 if AI-detected third-party code |
| `scancode_thirdparty_flag` | Int | 1 if license scanner detected third-party |
| `metadata` | String (JSON) | Full API response |

Note: Per-file line stats are in `gitlab_num_stat` (not inline), unlike GitHub where they are in `github_commit_files`.

---

### `gitlab_num_stat` — Per-file line changes (GitLab-specific)

| Field | Type | Description |
|-------|------|-------------|
| `commit_hash` | String | Parent commit — joins to `gitlab_commits.commit_hash` |
| `file_id` | Int | File path reference — joins to `gitlab_files.file_id` |
| `lines_added` | Int | Lines added in this file |
| `lines_removed` | Int | Lines removed in this file |
| `ai_thirdparty_flag` | Int | AI-detected third-party code |
| `scancode_thirdparty_flag` | Int | License scanner detected third-party |
| `scancode_metadata` | String (JSON) | License and copyright info |

Replaces `github_commit_files`. File paths are normalised into a separate lookup table (`gitlab_files`) to avoid repeating long path strings.

---

### `gitlab_files` — File path lookup (GitLab-specific)

| Field | Type | Description |
|-------|------|-------------|
| `file_id` | Int | Primary key |
| `file_path` | String | Full file path |
| `file_extension` | String | File extension |

Lookup table for file paths referenced by `gitlab_num_stat`. Normalised to reduce storage for repositories with many repeated file paths across commits.

---

### `gitlab_merge_requests`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Namespace |
| `repo_name` | String | Project slug |
| `mr_iid` | Int | MR number within the project (per-project unique) |
| `mr_id` | Int | Global MR ID across the GitLab instance |
| `title` | String | MR title |
| `body` | String | MR description |
| `state` | String | `opened` / `closed` / `merged` / `locked` |
| `work_in_progress` | Int | 1 if WIP / draft MR |
| `author_username` | String | MR author GitLab username |
| `author_email` | String | Author email |
| `head_branch` | String | Source branch |
| `base_branch` | String | Target branch |
| `created_at` | DateTime | MR creation time |
| `updated_at` | DateTime | Last update |
| `merged_at` | DateTime | Merge time (NULL if not merged) |
| `closed_at` | DateTime | Close time |
| `merged_by_username` | String | GitLab username of who merged |
| `merge_commit_hash` | String | Hash of merge commit |
| `files_changed` | Int | Files modified |
| `lines_added` | Int | Lines added |
| `lines_removed` | Int | Lines removed |
| `commit_count` | Int | Number of commits in MR |
| `comment_count` | Int | Number of comments |
| `duration_seconds` | Int | Time from creation to close |
| `ticket_refs` | String (JSON) | Extracted issue / ticket IDs |

---

### `gitlab_mr_approvals` — MR approvals (GitLab-specific)

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Namespace |
| `repo_name` | String | Project slug |
| `mr_iid` | Int | Parent MR |
| `approver_username` | String | Approver GitLab username |
| `approver_email` | String | Approver email — identity key |
| `approved_at` | DateTime | Approval timestamp |

Replaces `github_pull_request_reviews`. GitLab's approval model records only approvals — there is no `CHANGES_REQUESTED` or `DISMISSED` state equivalent.

---

### `gitlab_pull_request_comments`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Namespace |
| `repo_name` | String | Project slug |
| `mr_iid` | Int | Parent MR |
| `comment_id` | Int | Comment unique ID |
| `content` | String | Comment text (Markdown) |
| `author_username` | String | Comment author username |
| `author_email` | String | Author email — identity key |
| `created_at` | DateTime | Creation timestamp |
| `updated_at` | DateTime | Last update timestamp |
| `file_path` | String | File path for inline comments (NULL for general) |
| `line_number` | Int | Line number for inline comments (NULL for general) |

---

### `gitlab_pull_request_commits`

| Field | Type | Description |
|-------|------|-------------|
| `owner` | String | Namespace |
| `repo_name` | String | Project slug |
| `mr_iid` | Int | Parent MR |
| `commit_hash` | String | Commit SHA |
| `commit_order` | Int | Order within MR (0-indexed) |

---

### `gitlab_ticket_refs` — Ticket references extracted from MRs and commits

| Field | Type | Description |
|-------|------|-------------|
| `external_ticket_id` | String | Ticket ID, e.g. `PROJ-123` |
| `owner` | String | Namespace |
| `repo_name` | String | Project slug |
| `mr_iid` | Int | Associated MR (NULL if from commit) |
| `commit_hash` | String | Associated commit (NULL if from MR) |

---

### `gitlab_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier |
| `started_at` | DateTime | Run start time |
| `completed_at` | DateTime | Run end time |
| `status` | String | `running` / `completed` / `failed` |
| `repos_processed` | Int | Repositories processed |
| `commits_collected` | Int | Commits collected |
| `mrs_collected` | Int | Merge requests collected |
| `api_calls` | Int | API calls made |
| `errors` | Int | Errors encountered |
| `settings` | String (JSON) | Collection configuration (namespace, projects, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`author_email` in `gitlab_commits` is the primary identity key — mapped to canonical `person_id` via Identity Manager in Silver step 2.

`author_username` (GitLab username) is GitLab-internal and not used for cross-system resolution. Email takes precedence.

`approver_email` in `gitlab_mr_approvals` and `author_email` in `gitlab_pull_request_comments` are resolved to `person_id` in the same Silver step 2.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `gitlab_commits` | `class_commits` | Planned — stream not yet defined |
| `gitlab_merge_requests` | `class_pr_activity` | Planned — stream not yet defined |
| `gitlab_ticket_refs` | Cross-domain join → `class_task_tracker_activities.task_id` | Planned |
| `gitlab_repositories` | *(reference table)* | No unified stream |
| `gitlab_branches` | *(reference table)* | No unified stream |
| `gitlab_num_stat` + `gitlab_files` | *(granular detail)* | Available — no unified stream defined yet |
| `gitlab_mr_approvals` | *(review analytics)* | Available — no unified stream defined yet |
| `gitlab_pull_request_comments` | *(review analytics)* | Available — no unified stream defined yet |

**Gold**: Same as GitHub — commit-level and MR-level Gold metrics derived from unified `class_commits` and `class_pr_activity` streams once defined.

---

## Open Questions

### OQ-GL-1: `mr_iid` vs `mr_id` as the primary MR identifier

GitLab exposes two MR identifiers: `mr_iid` (per-project, human-readable, e.g. `!42`) and `mr_id` (global across the GitLab instance). When unifying with GitHub `pr_number` and Bitbucket `pr_number` in `class_pr_activity`:

- Which GitLab identifier maps to the unified `pr_id` field?
- `mr_iid` is more natural for display; `mr_id` is globally unique.

### OQ-GL-2: `gitlab_num_stat` vs inline file stats in commits

GitLab stores file-level line changes in a separate `gitlab_num_stat` table (with `gitlab_files` as a path lookup), unlike GitHub which inlines them in `github_commit_files`. When building `class_commits`:

- Is the per-file breakdown unified across sources (requiring a join for GitLab but not GitHub)?
- Or does `class_commits` only include summary-level stats (`files_changed`, `lines_added`, `lines_removed`) and leave file-level detail as source-specific Bronze analytics?

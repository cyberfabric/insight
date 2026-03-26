# PRD — Bitbucket Server Connector

> Version 1.3 — March 2026
> Based on: Unified git data model (`docs/components/connectors/git/README.md`)

<!-- toc -->

- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background--problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
  - [2.2 System Actors](#22-system-actors)
- [3. Operational Concept & Environment](#3-operational-concept--environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 Repository Discovery](#51-repository-discovery)
  - [5.2 Commit Collection](#52-commit-collection)
  - [5.3 Pull Request Collection](#53-pull-request-collection)
  - [5.4 Review and Comment Collection](#54-review-and-comment-collection)
  - [5.5 Incremental Collection](#55-incremental-collection)
  - [5.6 Fault Tolerance and Resilience](#56-fault-tolerance-and-resilience)
  - [5.7 Metadata & Admin Collection](#57-metadata--admin-collection)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Open Questions](#13-open-questions)
  - [OQ-BB-1: Author name format handling](#oq-bb-1-author-name-format-handling)
  - [OQ-BB-2: API cache retention policy](#oq-bb-2-api-cache-retention-policy)
  - [OQ-BB-3: Participant vs Reviewer distinction](#oq-bb-3-participant-vs-reviewer-distinction)

<!-- /toc -->

---

## 1. Overview

### 1.1 Purpose

The Bitbucket Server connector extracts version control data — repositories, branches, commits, pull requests, reviews, and comments — from self-hosted Bitbucket Server and Bitbucket Data Center instances. It emits structured messages to stdout following the Airbyte protocol, enabling an orchestrator to route records to Bronze tables for downstream dbt transformation into unified cross-platform analytics.

### 1.2 Background / Problem Statement

Organizations running Bitbucket Server on-premises lack centralized visibility into their engineering activity alongside teams on other git platforms. Engineering analytics teams need to track commit history, pull request cycle times, reviewer participation, and code change patterns across all source control systems. Without a Bitbucket connector, Bitbucket-hosted projects are excluded from platform-wide reports such as contributor throughput, review coverage, and cross-team collaboration metrics.

Bitbucket Server differs from cloud git platforms in several ways that require specific handling: its review model is limited to `APPROVE`/`UNAPPROVE` states, author names commonly use dot-separated corporate formatting, repository metadata such as creation date and language detection is not available via the API, and Bitbucket supports inline PR tasks (checkboxes in comments) as a distinct concept.

### 1.3 Goals (Business Outcomes)

- Collect all repositories, branches, commits, pull requests, reviewer actions, and comments from Bitbucket Server instances.
- Emit collected raw data as Airbyte protocol RECORD messages to stdout, with `data_source = "insight_bitbucket_server"` included in each record. An orchestrator routes records to Bronze tables; dbt transforms Bronze to unified `git_*` Silver tables.
- Support incremental collection so that repeated runs only fetch data that changed since the last successful run.
- Support multiple connector instances per Bitbucket Server (e.g., different tokens/project scopes). Each instance embeds its `instance_name` in stream names (`bitbucket_{instance}_{stream}`), so the orchestrator routes each instance to its own set of Bronze tables with no special routing config. dbt unions multiple instances in Silver.
- Tolerate API errors, deleted resources, and temporary outages without losing collection progress.

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Project | Bitbucket Server organizational grouping for repositories, identified by a `project_key` (e.g., `MYPROJ`) |
| Repository | A git repository within a project, identified by `repo_slug` (e.g., `my-repo`) |
| Pull Request (PR) | A code review request in Bitbucket, identified by a numeric `pr_id` within a repository |
| Activity | An event on a PR: comment, approval, unapproval, merge, etc. |
| Reviewer | A user explicitly assigned to review a pull request |
| Participant | A user who interacted with a PR (commented or acted) without being a formal reviewer |
| Task | An inline checkbox within a PR comment, Bitbucket-specific concept |
| `data_source` | Discriminator field injected by the connector into all Bronze records; propagated to Silver tables by dbt. Value for this connector is `"insight_bitbucket_server"` |
| Airbyte protocol | Message format for connector output: RECORD (data), STATE (cursor checkpoint), LOG (status/errors), CATALOG (stream schema). Connector emits JSON messages to stdout; orchestrator consumes them |
| RECORD message | Airbyte protocol message containing one extracted record: `{"type": "RECORD", "record": {"stream": "...", "data": {...}, "emitted_at": ...}}` |
| STATE message | Airbyte protocol message containing cursor checkpoint: `{"type": "STATE", "state": {"data": {...}}}`. Orchestrator persists state; connector reads it on next run |
| Incremental sync | Collection mode where only new or updated records are fetched, based on cursor state |
| `instance_name` | User-configured identifier for a connector instance (e.g., `team-alpha`). Determines Bronze table naming (`bitbucket_{instance}_{stream}`) and disambiguates multiple instances against the same Bitbucket Server |
| PAT | Personal Access Token — one of the supported authentication methods |

---

## 2. Actors

### 2.1 Human Actors

#### Platform / Data Engineer

**ID**: `cpt-insightspec-actor-bb-platform-engineer`

**Role**: Deploys and operates the Bitbucket Server connector; configures credentials, scope, and schedule.
**Needs**: Clear configuration interface, visibility into collection status and errors, ability to re-run failed collections without data loss or duplication.

#### Analytics Engineer

**ID**: `cpt-insightspec-actor-bb-analytics-eng`

**Role**: Consumes unified `git_*` Silver tables produced by dbt transformations from Bronze data to build Gold-layer analytics, reports, and dashboards.
**Needs**: Bitbucket data to be in the same schema as GitHub/GitLab data; nullable fields for missing Bitbucket metadata to be well-documented; Bitbucket-specific fields (task count, comment severity) to be accessible.

#### Engineering Manager / Director

**ID**: `cpt-insightspec-actor-bb-eng-manager`

**Role**: Consumes Gold-layer reports that aggregate Bitbucket activity alongside other platforms.
**Needs**: Accurate contributor attribution, PR cycle time metrics, and review participation data that reflects Bitbucket team activity.

### 2.2 System Actors

#### Bitbucket Server REST API

**ID**: `cpt-insightspec-actor-bb-api`

**Role**: Source system — provides project, repository, branch, commit, pull request, and activity data via the REST API v1.0.

#### ETL Scheduler / Orchestrator

**ID**: `cpt-insightspec-actor-bb-scheduler`

**Role**: Triggers connector runs on a configured schedule and monitors collection run outcomes.

---

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires network access to the organization's self-hosted Bitbucket Server or Data Center instance.
- Authentication credentials (Basic Auth / Bearer Token / PAT) must be provisioned with read access to all target projects and repositories.
- The connector operates in batch pull mode only; it does not require an inbound network port or webhook endpoint.
- The connector emits Airbyte protocol messages to stdout. It does NOT write to databases directly. An orchestrator (Airbyte or compatible) consumes stdout, routes RECORD messages to Bronze tables, and persists STATE messages for incremental sync.
- The connector has no dependency on ClickHouse or any specific database driver.
- Compatible with Bitbucket Server REST API v1.0; Bitbucket Data Center uses the same API surface.

---

## 4. Scope

### 4.1 In Scope

- Discovery and collection of all accessible Bitbucket Server projects and repositories.
- Collection of all branches per repository.
- Incremental collection of commit history per branch, including per-file line change statistics.
- Collection of pull requests across all states (open, merged, declined).
- Collection of PR reviewer assignments and review actions (approve / unapprove).
- Collection of PR comments (general and inline), including Bitbucket task state and severity.
- Collection of PR-to-commit linkage.
- Incremental collection strategy: only fetch data changed since the last run.
- Checkpoint-based fault tolerance: save progress after each repository, support resume on failure.
- Recording of connector execution statistics in a collection runs log.
- Collection of access control and permission data: project permissions, repository permissions, and global permissions for users and groups. *(Added in v1.1)*
- Collection of PR participant data embedded within pull request records (user, role, approval status). *(Added in v1.1)*
- Collection of commit build statuses from CI/CD integrations. *(Added in v1.1)*
- Collection of git tags per repository. *(Added in v1.1)*
- Collection of Bitbucket user directory (standalone user inventory with active status and account type). *(Added in v1.1)*
- Collection of user group memberships. *(Added in v1.1)*
- Collection of webhook configurations per repository. *(Added in v1.1)*
- Collection of branch restriction rules. *(Added in v1.1)*
- Collection of repository hook (server-side) configurations. *(Added in v1.1)*
- Collection of per-repository PR merge strategy configuration. *(Added in v1.1)*
- Collection of branching model configuration per repository. *(Added in v1.1)*
- Collection of instance-level server properties and metadata. *(Added in v1.1)*
- Support for multiple connector instances per Bitbucket Server, each with its own credentials, project scope, and Bronze table set. *(Added in v1.3)*
- Collection of default reviewer rules per repository. *(Added in v1.1)*
- Collection of PR merge eligibility (pre-merge condition checks). *(Added in v1.1)*

### 4.2 Out of Scope

- Bitbucket Cloud (separate API and auth model).
- Webhook-based real-time ingestion (batch pull only in this version).
- Collection of Bitbucket-native CI/CD pipeline data (Bamboo, Bitbucket Pipelines).
- ~~Collection of access control and permission data.~~ *(Moved to In Scope in v1.1)*
- Collection of repository wiki or issue tracker content.
- Repository mirroring or replication.
- Gold-layer transformations (owned by analytics pipeline, not this connector).
- ~~Participant tracking as a separate entity (participants are implicit from comments; see OQ-BB-3).~~ *(Moved to In Scope in v1.1 — participants embedded in PR record; see OQ-BB-3 resolution)*

---

## 5. Functional Requirements

### 5.1 Repository Discovery

#### Discover Projects and Repositories

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-discover-repos`

The connector MUST enumerate all accessible Bitbucket Server projects and their repositories using the REST API, and record repository metadata (name, slug, project key, visibility, fork policy) in the Bronze `bitbucket_repositories` stream. Additionally, the connector MUST collect repository state (`AVAILABLE`, `INITIALISING`, `OFFLINE`), archived flag, clone URLs (HTTP and SSH), web URL, and fork hierarchy identifier (origin repository reference for forked repositories).

**Rationale**: Cross-platform analytics require a complete inventory of all repositories, not a manually maintained list.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Discover Branches

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-discover-branches`

The connector MUST enumerate all branches per repository and track the branch state to support incremental commit collection.

**Actors**: `cpt-insightspec-actor-bb-api`

### 5.2 Commit Collection

#### Collect Commit History

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-commits`

The connector MUST collect the full commit history for each branch, including author name, author email, committer name, committer email, commit message, timestamp, and parent commit references.

**Rationale**: Commit history is the primary signal for contributor activity analytics.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Collect Per-File Line Changes

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-commit-files`

The connector MUST collect per-file line change statistics (file path, lines added, lines removed) for each commit. Additionally, the connector MUST collect the change type classification (`ADD`, `MODIFY`, `DELETE`, `MOVE`, `COPY`), node type (`FILE`, `SUBMODULE`), executable bit, blob content SHAs (source and destination), and parent directory path for each changed file.

**Rationale**: File-level data enables code churn analysis, language breakdown, and hotspot detection.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`, `cpt-insightspec-actor-bb-api`

#### Detect Merge Commits

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-detect-merge-commits`

The connector MUST identify and flag merge commits (commits with more than one parent) so they can be excluded from or weighted appropriately in contribution metrics.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`

### 5.3 Pull Request Collection

#### Collect Pull Request Metadata

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-prs`

The connector MUST collect all pull requests across all states (open, merged, declined), including title, description, author, source branch, destination branch, state, timestamps (created, updated, closed), and merge commit reference. Additionally, the connector MUST collect draft and locked flags, source and target HEAD commit SHAs, the full reviewer list with per-reviewer approval status, the participants list, browser URL, merge result currency (whether the merge result is current with the source branch), and task/comment counts from API properties.

**Actors**: `cpt-insightspec-actor-bb-eng-manager`, `cpt-insightspec-actor-bb-api`

#### Collect PR Statistics

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-pr-stats`

The connector MUST populate PR-level statistics: commit count, comment count, task count (Bitbucket-specific), and file-level change counts (files changed, lines added, lines removed).

**Rationale**: PR size and comment volume are key inputs to cycle time and review quality metrics.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`

#### Collect PR-to-Commit Linkage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-pr-commits`

The connector MUST collect the set of commits associated with each pull request.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`

### 5.4 Review and Comment Collection

#### Collect Reviewer Assignments and Actions

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-reviewers`

The connector MUST collect reviewer assignments and review actions (approve / unapprove) for each pull request, including reviewer identity and the timestamp of the review action.

**Rationale**: Reviewer participation is a key metric for engineering team process analytics.

**Actors**: `cpt-insightspec-actor-bb-eng-manager`, `cpt-insightspec-actor-bb-api`

**Note**: Bitbucket's review model supports `APPROVED`, `UNAPPROVED`, and `NEEDS_WORK` states. The connector MUST map these to the unified schema `status` field; it MUST NOT fabricate states not present in the Bitbucket API (`CHANGES_REQUESTED`, `COMMENTED`).

#### Collect PR Comments

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-comments`

The connector MUST collect all PR comments (both general and inline), including comment author, content, timestamps (created, updated), and Bitbucket-specific fields: task state (`OPEN`/`RESOLVED`), severity (`NORMAL`/`BLOCKER`), thread resolution status, and inline anchor (file path and line number where applicable). Additionally, the connector MUST collect comment version tracking (version number for edit history), parent comment ID for nested reply threading, anchor detail fields (base and head commit SHAs, line type, file type, source path for renames, diff type), and orphaned anchor detection for comments invalidated by force-pushes or rebases.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`

#### Collect PR Activity Types (UPDATED and RESCOPED)

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-collect-pr-activity-types`

The connector MUST collect UPDATED and RESCOPED activity types from the PR activities stream. UPDATED activities capture reviewer additions and removals (`addedReviewers`, `removedReviewers`). RESCOPED activities capture force-push events including the previous and new HEAD SHAs (`fromHash`, `toHash`) and the lists of added and removed commits. Both activity types MUST be emitted as RECORD messages on the `bitbucket_pr_activities` stream.

**Rationale**: Reviewer change history and force-push tracking are essential for understanding PR lifecycle dynamics beyond simple approve/comment events. RESCOPED events reveal rebases and force-pushes that affect commit lineage.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`, `cpt-insightspec-actor-bb-api`

### 5.5 Incremental Collection

#### Track Collection Cursors

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-incremental-cursors`

The connector MUST maintain per-branch commit cursors (last collected commit hash) and per-repository PR cursors (last collected `updatedDate` timestamp) to support incremental collection. Cursor state is received from the orchestrator at startup (previous STATE message) and emitted as a STATE message at the end of each run. The state storage mechanism is opaque to the connector — it may be a JSON file, database table, or other persistent store managed by the orchestrator. Additionally, the connector MUST implement sub-stream cursor inheritance: PR Activities, PR Changes, PR Commits, and PR Merge Eligibility are fetched only for PRs updated since last sync (driven by the PR cursor). Build statuses are fetched only for new commits (piggybacked on the commit SHA cursor).

**Rationale**: Full re-collection of large repositories is prohibitively expensive; incremental runs must complete in reasonable time.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

#### Early Exit on Stale Data

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-early-exit`

The connector MUST stop fetching commits for a branch when it encounters a commit already present in the collection state. The connector MUST stop fetching pull requests when it encounters a PR whose `updated_on` timestamp is before the last collection cursor.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

#### Record Collection Run Metadata

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-collection-runs`

The connector MUST emit LOG messages with start time, end time, status, and item counts (repositories processed, commits collected, PRs collected, errors encountered) for each collection run.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

### 5.6 Fault Tolerance and Resilience

#### Retry on Transient Errors

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-retry`

The connector MUST retry API calls that fail with transient errors (HTTP 429, 500, 502, 503) using exponential backoff. The maximum number of retries and base delay MUST be configurable.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

#### Continue on Non-Fatal Errors

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-continue-on-error`

The connector MUST continue collection when individual items fail with non-fatal errors (HTTP 404 for deleted resources, malformed API responses). It MUST log the error, skip the affected item, and continue with the next item.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

#### Checkpoint and Resume

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-checkpoint`

The connector MUST emit STATE messages after completing each repository so that a failed run can be resumed from the last successful checkpoint rather than restarting from the beginning. The orchestrator persists STATE messages; on restart, it provides the last persisted STATE to the connector.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

### 5.7 Metadata & Admin Collection

#### Collect CI Build Statuses

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-collect-builds`

The connector MUST collect CI build statuses for each commit via the build-status API (`GET /rest/build-status/1.0/commits/{hash}`). Each build status record MUST include: state (SUCCESSFUL, FAILED, INPROGRESS), build key, build name, build URL, description, and timestamp. Build statuses MUST be emitted as RECORD messages on the `bitbucket_build_statuses` stream.

**Rationale**: Build status data enables CI/CD pipeline analytics, build success rate tracking, and correlation of build health with PR merge velocity.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`, `cpt-insightspec-actor-bb-api`

#### Collect Tags

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-collect-tags`

The connector MUST collect all tags per repository via the REST API (`GET /rest/api/1.0/projects/{key}/repos/{slug}/tags`), including the tag display name, the full ref ID, the latest commit SHA (for annotated tags this is the commit the tag points to), and the tag hash.

**Rationale**: Tags mark releases and version milestones. Collecting tags enables release frequency analytics and mapping deployments to commit ranges.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`, `cpt-insightspec-actor-bb-api`

#### Collect User Inventory

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-collect-users`

The connector MUST collect a standalone user inventory via the REST API (`GET /rest/api/1.0/users`), recording user ID, username, slug, display name, email address, active status, and account type (NORMAL or SERVICE). When the connector authenticates with admin privileges, it MUST additionally collect: account creation timestamp, last authentication timestamp, deletable flag, directory name, and mutable details/groups flags. All user records MUST be emitted as RECORD messages on the `bitbucket_users` stream.

**Rationale**: A complete user inventory is required for contributor activity reporting and detecting inactive or service accounts.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Collect Groups and Group Membership

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-groups`

The connector MUST collect admin groups via the REST API (`GET /rest/api/1.0/admin/groups`) and group membership via the group members endpoint (`GET /rest/api/1.0/admin/groups/more-members?context={group}`). Group records MUST include group name and deletable flag. Group membership records MUST include the group name and the full user object for each member. Groups MUST be emitted as RECORD messages on the `bitbucket_groups` stream and membership on the `bitbucket_group_members` stream. This stream requires admin permissions and the connector MUST gracefully skip collection with a warning if the authenticated user lacks admin access.

**Rationale**: Group inventory and membership data support access audit, permission analysis, and organizational structure mapping.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Check PR Merge Eligibility

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-pr-merge-eligibility`

The connector MUST check merge readiness for each open pull request via the merge endpoint (`GET /rest/api/1.0/projects/{key}/repos/{slug}/pull-requests/{id}/merge`). The connector MUST record: canMerge flag, conflicted flag, merge outcome (CLEAN, CONFLICTED, UNKNOWN), and the list of vetoes (summary and detailed messages explaining why merge is blocked). Results MUST be emitted as RECORD messages on the `bitbucket_pr_merge_eligibility` stream.

**Rationale**: Merge eligibility data reveals bottlenecks in the PR pipeline — whether PRs are blocked by failing builds, insufficient approvals, or unresolved tasks — enabling targeted process improvements.

**Actors**: `cpt-insightspec-actor-bb-eng-manager`, `cpt-insightspec-actor-bb-api`

#### Collect Permission Assignments

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-permissions`

The connector MUST collect permission assignments at three scopes: project-level (users and groups), repository-level (users and groups), and global-level (users and groups) via the corresponding REST API permissions endpoints. Each record MUST include the scope context (project key and/or repo slug where applicable), the user or group identity, and the permission level (e.g., PROJECT_READ, PROJECT_WRITE, PROJECT_ADMIN, REPO_READ, REPO_WRITE, REPO_ADMIN, LICENSED_USER, PROJECT_CREATE, ADMIN, SYS_ADMIN). All records MUST be emitted as RECORD messages on the `bitbucket_permissions` stream. Global permission endpoints require admin access; the connector MUST gracefully skip with a warning if the authenticated user lacks admin permissions.

**Rationale**: Permission data enables access audit, least-privilege analysis, and compliance reporting across the Bitbucket instance.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Collect Webhook Configurations

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-webhooks`

The connector MUST collect webhook configurations per repository via the REST API (`GET /rest/api/1.0/projects/{key}/repos/{slug}/webhooks`). Each webhook record MUST include: webhook ID, name, target URL, active flag, subscribed events list, scope type (repository or project), SSL verification flag, creation and update timestamps, and configuration metadata. Records MUST be emitted as RECORD messages on the `bitbucket_webhooks` stream.

**Rationale**: Webhook configuration data supports integration audit — understanding which repositories have CI/CD hooks, notification hooks, or third-party integrations configured.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Collect Branch Protection Rules

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-branch-restrictions`

The connector MUST collect branch restriction rules per repository via the branch permissions API (`GET /rest/branch-permissions/2.0/projects/{key}/repos/{slug}/restrictions`). Each restriction record MUST include: restriction ID, scope (REPOSITORY or PROJECT), restriction type (no-deletes, read-only, pull-request-only, fast-forward-only), branch matcher (ref pattern, matcher type, active flag), and lists of exempted users, groups, and access keys. Records MUST be emitted as RECORD messages on the `bitbucket_branch_restrictions` stream.

**Rationale**: Branch protection rules are critical governance metadata. Collecting them enables compliance auditing — verifying that main branches require PR-only merges, that appropriate exemptions are in place, and that protection policies are consistent across repositories.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Collect Repository Hook Configurations

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-repo-hooks`

The connector MUST collect repository hook (plugin) configurations per repository via the REST API (`GET /rest/api/1.0/projects/{key}/repos/{slug}/settings/hooks`). Each hook record MUST include: hook key, name, type (PRE_RECEIVE, POST_RECEIVE, PRE_PULL_REQUEST_MERGE), description, plugin version, applicable scope types, enabled flag, configured flag, and scope details. Records MUST be emitted as RECORD messages on the `bitbucket_repo_hooks` stream.

**Rationale**: Repository hooks enforce server-side policies (committer verification, merge checks). Collecting hook configurations supports governance auditing and ensures critical hooks are consistently enabled across repositories.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Collect PR Merge Strategy Configuration

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-pr-merge-config`

The connector MUST collect pull request merge configuration per repository via the REST API (`GET /rest/api/1.0/projects/{key}/repos/{slug}/settings/pull-requests`). The record MUST include: merge config type (DEFAULT, REPOSITORY, PROJECT), default merge strategy (no-ff, squash, ff-only), list of all available strategies with enabled flags, required approver count, required-all-approvers flag, required-all-tasks-complete flag, required successful builds count, and commit summary settings. Records MUST be emitted as RECORD messages on the `bitbucket_pr_merge_config` stream.

**Rationale**: Merge strategy and approval requirements directly impact code quality governance. Collecting this configuration enables analysis of merge policy consistency across repositories and identification of repos with insufficient merge guards.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Collect Branch Model

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-branch-model`

The connector MUST collect the branch model configuration per repository via the REST API (`GET /rest/branch-utils/1.0/projects/{key}/repos/{slug}/branchmodel`). The record MUST include: the development branch reference (ref ID, display name, whether it is the default branch, latest commit), and the list of branch type definitions (type ID, display name, prefix pattern). Records MUST be emitted as RECORD messages on the `bitbucket_branch_model` stream.

**Rationale**: Branch model data reveals how teams structure their branching workflow (GitFlow, trunk-based, etc.) and enables analytics on branch naming convention compliance.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`, `cpt-insightspec-actor-bb-api`

#### Collect Server Version and Build Info

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-server-info`

The connector MUST collect server version and build information via the application properties endpoint (`GET /rest/api/1.0/application-properties`). The record MUST include: server version string, build number, build date timestamp, and display name. Records MUST be emitted as RECORD messages on the `bitbucket_application_properties` stream.

**Rationale**: Server version data enables the connector to adapt behavior to API version differences and provides operational metadata for troubleshooting collection issues tied to specific Bitbucket Server releases.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

#### Collect Default Reviewer Conditions

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-collect-default-reviewers`

The connector MUST collect default reviewer conditions per repository via the REST API (`GET /rest/default-reviewers/1.0/projects/{key}/repos/{slug}/conditions`). Each condition record MUST include: condition ID, source branch matcher (ref pattern and matcher type), target branch matcher (ref pattern and matcher type), the list of default reviewer users, and the required approval count. Records MUST be emitted as RECORD messages on the `bitbucket_default_reviewers` stream.

**Rationale**: Default reviewer conditions automate code review assignments. Collecting them enables audit of review coverage — verifying that critical code paths have mandatory reviewers assigned and that review policies are consistently applied.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`, `cpt-insightspec-actor-bb-api`

---

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Authentication Flexibility

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bb-auth`

The connector MUST support HTTP Basic Auth, Bearer Token, and Personal Access Token (PAT) authentication methods, configurable without code changes.

#### Configurable Rate Limiting

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-bb-rate-limiting`

The connector MUST support configurable inter-request sleep intervals and pagination page size. It MUST implement exponential backoff on HTTP 429 responses.

**Threshold**: Configurable sleep between requests (default 100 ms); page size configurable up to 1000 (default 100).

#### Unified Schema Compliance

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bb-schema-compliance`

All extracted data MUST be emitted as Airbyte protocol RECORD messages to stdout. Each RECORD specifies a stream name (e.g., `bitbucket_commits`, `bitbucket_permissions`). The connector does NOT write to databases directly — an orchestrator routes RECORD messages to Bronze tables. Stream names follow the `bitbucket_{stream}` convention for all tiers.

#### Data Source Discriminator

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bb-data-source`

All RECORD messages MUST include `data_source = "insight_bitbucket_server"` in the record data to enable source-level filtering and deduplication in downstream queries.

#### Idempotent Writes

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bb-idempotent`

The connector MUST emit deterministic RECORD messages: given the same input state and API data, repeated runs MUST produce identical output records. Deduplication and upsert semantics are the responsibility of the orchestrator and write layer, not the connector.

### 6.2 NFR Exclusions

- **Real-time latency SLA**: Not applicable — the connector operates in scheduled batch pull mode only; sub-minute latency is not required.
- **GPU / high-compute NFRs**: Not applicable — the connector performs I/O-bound REST API collection with no computational requirements.

---

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Connector Entry Point

- [ ] `p1` - **ID**: `cpt-insightspec-interface-bb-entrypoint`

**Type**: CLI / Python module

**Stability**: stable

**Description**: The connector exposes a `collect` command (or callable) that accepts configuration (base URL, credentials, project scope, instance name) and emits Airbyte protocol messages (RECORD, STATE, LOG) to stdout. The orchestrator invokes the connector as a subprocess and consumes its stdout.

**Breaking Change Policy**: Configuration schema changes require a version bump and migration guide.

### 7.2 External Integration Contracts

#### Bitbucket Server REST API Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-bb-api`

**Direction**: required from client (Bitbucket Server instance)

**Protocol/Format**: HTTP/REST, JSON responses

**Compatibility**: API v1.0; no backwards-incompatible changes expected within Bitbucket Server 7.x / 8.x / Data Center versions

#### Airbyte Protocol Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-bb-airbyte-protocol`

**Direction**: provided to orchestrator (stdout)

**Protocol/Format**: JSON-line messages to stdout. Message types: `RECORD` (extracted data), `STATE` (cursor checkpoint), `LOG` (status/errors), `CATALOG` (stream schema declarations). One JSON object per line.

**Compatibility**: Compatible with Airbyte protocol v0.2+. Custom orchestrators must implement RECORD/STATE/LOG message handling.

---

## 8. Use Cases

#### Full Initial Collection

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-bb-initial-collection`

**Actor**: `cpt-insightspec-actor-bb-platform-engineer`

**Preconditions**:
- Connector is configured with valid Bitbucket Server credentials and base URL.
- Target project keys are configured (or all-projects mode is enabled).
- No prior collection state exists.

**Main Flow**:
1. Platform Engineer triggers the connector run.
2. Connector enumerates all configured projects and their repositories.
3. For each repository: collect branches, then all commits per branch (full history), then all PRs with activities and file changes.
4. Connector emits RECORD messages to stdout with `data_source = "insight_bitbucket_server"` in each record.
5. Connector emits a final STATE message with cursor checkpoints and LOG messages with run statistics.

**Postconditions**:
- All repositories, commits, PRs, reviews, and comments have been emitted as RECORD messages to stdout.
- Collection run log shows `status = completed`.

**Alternative Flows**:
- **Authentication failure**: Connector halts and logs error; operator is notified.
- **Repository deleted mid-run**: HTTP 404 is logged as a warning; collection continues with the next repository.

#### Incremental Collection Run

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-bb-incremental`

**Actor**: `cpt-insightspec-actor-bb-scheduler`

**Preconditions**:
- At least one prior successful collection run exists.
- Branch-level commit cursors and PR update timestamps are stored.

**Main Flow**:
1. Scheduler triggers connector run on configured schedule.
2. Orchestrator provides previous STATE to connector (cursor checkpoints).
3. For each branch: fetch commits only up to the last known commit hash; stop at cursor.
4. For PRs: fetch with `order=NEWEST`; stop when `updated_on` < last cursor.
5. Emit only new/changed records as RECORD messages; skip unchanged items.
6. Emit STATE message with updated cursors for next run.

**Postconditions**:
- Only new or updated data is emitted as RECORD messages.
- Run completes significantly faster than a full collection.

---

## 9. Acceptance Criteria

- [ ] All repositories, branches, commits, PRs, reviews, and comments from a sample Bitbucket Server instance are emitted as RECORD messages to stdout during a full collection run.
- [ ] `data_source = "insight_bitbucket_server"` is set on every row written by this connector.
- [ ] A second collection run (incremental) emits only new/changed records (deterministic output given same state).
- [ ] An incremental run fetches only data updated since the last run (verified by comparing run durations and API call counts).
- [ ] Collection continues and completes when one repository returns 404 (deleted) or one PR returns a malformed response.
- [ ] Connector emits LOG messages with correct start time, end time, item counts, and status for each run.

- [ ] Permission data (project-level, repository-level, and global for both users and groups) is emitted as RECORD messages on the `bitbucket_permissions` stream after a full collection run.
- [ ] Build statuses for commits are emitted as RECORD messages on the `bitbucket_build_statuses` stream with state, URL, and timestamp for each build.
- [ ] Tags per repository are collected and stored with tag name, tagged commit hash, and tag object SHA.
- [ ] A standalone user inventory is collected, including account active/inactive status and user type (NORMAL / SERVICE).
- [ ] Group membership data is collected for all admin-visible groups, capturing group name and member list.
- [ ] PR merge eligibility (canMerge flag, vetoes list) is collected for all open pull requests.
- [ ] Repository metadata includes state (AVAILABLE / INITIALISING / OFFLINE), archived flag, and at least one clone URL per repository.
- [ ] PR comments include nested reply threading (parent comment reference) and orphaned anchor detection for file-level comments on outdated diffs.

---

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Bitbucket Server REST API v1.0 | Source data — all collected data originates from this API | `p1` |
| Airbyte-compatible orchestrator | Consumes stdout RECORD/STATE/LOG messages, routes to Bronze tables | `p1` |
| ETL Scheduler / Orchestrator | Triggers collection runs on schedule | `p2` |

---

## 11. Assumptions

- The Bitbucket Server instance is accessible from the connector's deployment environment over HTTPS.
- The provided credentials have read access to all configured projects and repositories.
- The Bitbucket Server REST API v1.0 is available and stable on the target instance (Bitbucket Server 6.x+ or Data Center).
- An Airbyte-compatible orchestrator is available to consume connector stdout and route records to Bronze tables.

---

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Bitbucket Server instance not accessible (network, firewall) | Collection fails entirely | Fail-fast with clear error message; operational runbook for network configuration |
| API credentials expire or are revoked | Collection fails with 401/403 | Alert on auth failures; document credential rotation procedure |
| Large repositories with deep commit history cause slow initial collection | First run takes hours | Support configurable history depth limit for initial collection; document expected run times |
| Bitbucket API rate limiting enforced by organization | Throttled or blocked requests | Configurable inter-request delay + exponential backoff; default conservative settings |
| Author email absent from Bitbucket commits | Downstream dbt identity resolution cannot match by email | Connector stores raw author name and email as-is in Bronze; dbt handles fallback logic |

---

## 13. Open Questions

### OQ-BB-1: Author name format handling

Bitbucket author names frequently use dot-separated corporate format (e.g., `John.Smith`) while GitHub uses various formats (`johndoe`, `John Doe`).

**Question**: Should the connector normalize author names during Silver-layer mapping, or preserve the raw Bitbucket format and delegate normalization to Gold-layer identity resolution?

**Resolution (v1.2)**: Resolved — the connector stores raw Bitbucket author names as-is in Bronze. Normalization is handled by dbt Silver-layer transformations.

**Status**: CLOSED

---

### OQ-BB-2: API cache retention policy

**Question**: What is the recommended retention period for cached API responses?

**Resolution (v1.3)**: Resolved — API caching is removed from the connector. The Bronze layer stores all collected data permanently. Data retention is an infrastructure/ops concern, not a connector concern. The `bitbucket_api_cache` concept is eliminated.

**Status**: CLOSED

---

### OQ-BB-3: Participant vs Reviewer distinction

Bitbucket distinguishes between formally assigned reviewers and participants (users who commented or otherwise interacted with a PR).

**Question**: Should the schema include a separate participant tracking table, or should participant roles be merged into the reviewer table using a `role` discriminator field?

**Current approach** (superseded): Only formal reviewers were emitted; participants were implicit from comment authors.

**Consideration**: Explicit participant data supports collaboration graph analytics but may duplicate comment-author data already present in the comments table.

**Resolution (v1.1)**: Resolved — participants are stored as an embedded JSON array (`participants[]`) within the pull request record. Each entry contains `user`, `role` (PARTICIPANT / REVIEWER / AUTHOR), and `approved` status. No separate participant table is created. This approach preserves explicit participant data for collaboration graph analytics while avoiding table proliferation. See DESIGN.md field mapping and stream inventory for implementation details.

**Status**: CLOSED


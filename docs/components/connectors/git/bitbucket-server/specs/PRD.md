# PRD — Bitbucket Server Connector

> Version 1.0 — March 2026
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
  - [5.5 Identity Resolution](#55-identity-resolution)
  - [5.6 Incremental Collection](#56-incremental-collection)
  - [5.7 Fault Tolerance and Resilience](#57-fault-tolerance-and-resilience)
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

The Bitbucket Server connector collects version control data — repositories, branches, commits, pull requests, reviews, and comments — from self-hosted Bitbucket Server and Bitbucket Data Center instances. It integrates into the unified git pipeline, enabling cross-platform analytics alongside GitHub and GitLab data.

### 1.2 Background / Problem Statement

Organizations running Bitbucket Server on-premises lack centralized visibility into their engineering activity alongside teams on other git platforms. Engineering analytics teams need to track commit history, pull request cycle times, reviewer participation, and code change patterns across all source control systems. Without a Bitbucket connector, Bitbucket-hosted projects are excluded from platform-wide reports such as contributor throughput, review coverage, and cross-team collaboration metrics.

Bitbucket Server differs from cloud git platforms in several ways that require specific handling: its review model is limited to `APPROVE`/`UNAPPROVE` states, author names commonly use dot-separated corporate formatting, repository metadata such as creation date and language detection is not available via the API, and Bitbucket supports inline PR tasks (checkboxes in comments) as a distinct concept.

### 1.3 Goals (Business Outcomes)

- Collect all repositories, branches, commits, pull requests, reviewer actions, and comments from Bitbucket Server instances.
- Store collected data in the unified `git_*` Silver tables using `data_source = "insight_bitbucket_server"` as the discriminator, enabling cross-platform queries alongside GitHub and GitLab data.
- Support incremental collection so that repeated runs only fetch data that changed since the last successful run.
- Resolve Bitbucket user identities (email, username) to canonical `person_id` via the Identity Manager, enabling cross-platform person analytics.
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
| `data_source` | Discriminator field in all unified `git_*` tables; value for this connector is `"insight_bitbucket_server"` |
| `person_id` | Canonical cross-system person identifier resolved by the Identity Manager |
| Incremental sync | Collection mode where only new or updated records are fetched, based on cursor state |
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

**Role**: Consumes unified `git_*` Silver tables to build Gold-layer analytics, reports, and dashboards.
**Needs**: Bitbucket data to be in the same schema as GitHub/GitLab data; nullable fields for missing Bitbucket metadata to be well-documented; Bitbucket-specific fields (task count, comment severity) to be accessible.

#### Engineering Manager / Director

**ID**: `cpt-insightspec-actor-bb-eng-manager`

**Role**: Consumes Gold-layer reports that aggregate Bitbucket activity alongside other platforms.
**Needs**: Accurate contributor attribution, PR cycle time metrics, and review participation data that reflects Bitbucket team activity.

### 2.2 System Actors

#### Bitbucket Server REST API

**ID**: `cpt-insightspec-actor-bb-api`

**Role**: Source system — provides project, repository, branch, commit, pull request, and activity data via the REST API v1.0.

#### Identity Manager

**ID**: `cpt-insightspec-actor-bb-identity-manager`

**Role**: Resolves Bitbucket user emails and usernames to canonical `person_id` values for cross-platform identity unification.

#### ETL Scheduler / Orchestrator

**ID**: `cpt-insightspec-actor-bb-scheduler`

**Role**: Triggers connector runs on a configured schedule and monitors collection run outcomes.

---

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires network access to the organization's self-hosted Bitbucket Server or Data Center instance.
- Authentication credentials (Basic Auth / Bearer Token / PAT) must be provisioned with read access to all target projects and repositories.
- The connector operates in batch pull mode only; it does not require an inbound network port or webhook endpoint.
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
- Extraction of ticket references (e.g., Jira issue keys) from PR titles, descriptions, and commit messages.
- Incremental collection strategy: only fetch data changed since the last run.
- Optional API response caching to reduce redundant API calls.
- Checkpoint-based fault tolerance: save progress after each repository, support resume on failure.
- Recording of connector execution statistics in a collection runs log.
- Identity resolution for commit authors and PR reviewers via the Identity Manager.

### 4.2 Out of Scope

- Bitbucket Cloud (separate API and auth model).
- Webhook-based real-time ingestion (batch pull only in this version).
- Collection of Bitbucket-native CI/CD pipeline data (Bamboo, Bitbucket Pipelines).
- Collection of access control and permission data.
- Collection of repository wiki or issue tracker content.
- Repository mirroring or replication.
- Gold-layer transformations (owned by analytics pipeline, not this connector).
- Participant tracking as a separate entity (participants are implicit from comments; see OQ-BB-3).

---

## 5. Functional Requirements

### 5.1 Repository Discovery

#### Discover Projects and Repositories

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-discover-repos`

The connector MUST enumerate all accessible Bitbucket Server projects and their repositories using the REST API, and record repository metadata (name, slug, project key, visibility, fork policy) in the unified repository table.

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

The connector MUST collect per-file line change statistics (file path, lines added, lines removed) for each commit.

**Rationale**: File-level data enables code churn analysis, language breakdown, and hotspot detection.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`, `cpt-insightspec-actor-bb-api`

#### Detect Merge Commits

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-detect-merge-commits`

The connector MUST identify and flag merge commits (commits with more than one parent) so they can be excluded from or weighted appropriately in contribution metrics.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`

### 5.3 Pull Request Collection

#### Collect Pull Request Metadata

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-prs`

The connector MUST collect all pull requests across all states (open, merged, declined), including title, description, author, source branch, destination branch, state, timestamps (created, updated, closed), and merge commit reference.

**Actors**: `cpt-insightspec-actor-bb-eng-manager`, `cpt-insightspec-actor-bb-api`

#### Collect PR Statistics

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-pr-stats`

The connector MUST populate PR-level statistics: commit count, comment count, task count (Bitbucket-specific), and file-level change counts (files changed, lines added, lines removed).

**Rationale**: PR size and comment volume are key inputs to cycle time and review quality metrics.

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`

#### Extract Ticket References

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-extract-tickets`

The connector MUST extract ticket references (e.g., Jira issue keys) from PR titles, descriptions, and commit messages, and store them in the ticket references table.

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

**Note**: Bitbucket's review model supports only `APPROVED` and `UNAPPROVED` states. The connector MUST map these to the unified schema `status` field; it MUST NOT fabricate states not present in the Bitbucket API (`CHANGES_REQUESTED`, `COMMENTED`).

#### Collect PR Comments

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-collect-comments`

The connector MUST collect all PR comments (both general and inline), including comment author, content, timestamps (created, updated), and Bitbucket-specific fields: task state (`OPEN`/`RESOLVED`), severity (`NORMAL`/`BLOCKER`), thread resolution status, and inline anchor (file path and line number where applicable).

**Actors**: `cpt-insightspec-actor-bb-analytics-eng`

### 5.5 Identity Resolution

#### Resolve Author and Reviewer Identities

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-identity-resolution`

The connector MUST resolve commit authors and PR reviewers to canonical `person_id` values via the Identity Manager. Email address is the primary resolution key; username (`author_name`) is the fallback when email is absent. Bitbucket numeric user IDs serve as a last-resort fallback.

**Rationale**: Cross-platform analytics require all persons to be unified under a single canonical identity regardless of their source platform representation.

**Actors**: `cpt-insightspec-actor-bb-identity-manager`, `cpt-insightspec-actor-bb-analytics-eng`

### 5.6 Incremental Collection

#### Track Collection Cursors

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-incremental-cursors`

The connector MUST maintain per-branch commit cursors (last collected commit hash and timestamp) and per-repository PR cursors (last collected updated timestamp) to support incremental collection runs that only fetch new or changed data.

**Rationale**: Full re-collection of large repositories is prohibitively expensive; incremental runs must complete in reasonable time.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

#### Early Exit on Stale Data

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bb-early-exit`

The connector MUST stop fetching commits for a branch when it encounters a commit already present in the collection state. The connector MUST stop fetching pull requests when it encounters a PR whose `updated_on` timestamp is before the last collection cursor.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

#### Record Collection Run Metadata

- [ ] `p2` - **ID**: `cpt-insightspec-fr-bb-collection-runs`

The connector MUST record the start time, end time, status, and item counts (repositories processed, commits collected, PRs collected, errors encountered) for each collection run in the collection runs log table.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

### 5.7 Fault Tolerance and Resilience

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

The connector MUST checkpoint its progress after completing each repository so that a failed run can be resumed from the last successful checkpoint rather than restarting from the beginning.

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

#### Optional API Response Caching

- [ ] `p3` - **ID**: `cpt-insightspec-fr-bb-api-cache`

The connector SHOULD support optional caching of API responses to reduce redundant API calls for frequently accessed, slow-changing data (e.g., repository metadata, branch lists). Caching MUST be configurable (enabled/disabled, TTL per data category).

**Actors**: `cpt-insightspec-actor-bb-platform-engineer`

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

All collected data MUST be stored in the unified `git_*` Silver tables defined in `docs/components/connectors/git/README.md`. The connector MUST NOT create Bitbucket-specific Silver tables (the Bronze `bitbucket_api_cache` table is the only Bitbucket-specific table).

#### Data Source Discriminator

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bb-data-source`

All rows written to unified tables MUST carry `data_source = "insight_bitbucket_server"` to enable source-level filtering and deduplication in cross-platform queries.

#### Idempotent Writes

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bb-idempotent`

Repeated collection of the same data MUST NOT create duplicate rows. The connector MUST use upsert semantics (keyed on natural primary keys) for all write operations.

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

**Description**: The connector exposes a `collect` command (or callable) that accepts configuration (base URL, credentials, project scope, schedule parameters) and executes a full or incremental collection run.

**Breaking Change Policy**: Configuration schema changes require a version bump and migration guide.

### 7.2 External Integration Contracts

#### Bitbucket Server REST API Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-bb-api`

**Direction**: required from client (Bitbucket Server instance)

**Protocol/Format**: HTTP/REST, JSON responses

**Compatibility**: API v1.0; no backwards-incompatible changes expected within Bitbucket Server 7.x / 8.x / Data Center versions

#### Identity Manager Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-bb-identity-mgr`

**Direction**: required from client (Identity Manager service)

**Protocol/Format**: Internal service call; input is email + name + source label; output is canonical `person_id`

**Compatibility**: Identity Manager must be available and responsive during collection runs

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
4. Connector writes all data to unified `git_*` Silver tables with `data_source = "insight_bitbucket_server"`.
5. Connector records the completed run in the collection runs log.

**Postconditions**:
- All repositories, commits, PRs, reviews, and comments are present in the Silver tables.
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
2. Connector reads cursors from `git_repository_branches` and `git_pull_requests`.
3. For each branch: fetch commits only up to the last known commit hash; stop at cursor.
4. For PRs: fetch with `order=NEWEST`; stop when `updated_on` < last cursor.
5. Write only new/changed records; skip unchanged items.
6. Update cursors for next run.

**Postconditions**:
- Only new or updated data is added to Silver tables.
- Run completes significantly faster than a full collection.

---

## 9. Acceptance Criteria

- [ ] All repositories, branches, commits, PRs, reviews, and comments from a sample Bitbucket Server instance are present in the unified `git_*` Silver tables after a full collection run.
- [ ] `data_source = "insight_bitbucket_server"` is set on every row written by this connector.
- [ ] A second collection run (incremental) completes without creating duplicate rows.
- [ ] An incremental run fetches only data updated since the last run (verified by comparing run durations and API call counts).
- [ ] Collection continues and completes when one repository returns 404 (deleted) or one PR returns a malformed response.
- [ ] Identity resolution populates `person_id` for all commit authors and reviewers that have a matching email in the Identity Manager.
- [ ] Collection run log records correct start time, end time, item counts, and status for each run.

---

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Bitbucket Server REST API v1.0 | Source data — all collected data originates from this API | `p1` |
| Unified `git_*` Silver tables | Target schema defined in `docs/components/connectors/git/README.md` | `p1` |
| Identity Manager | Resolves author emails and usernames to canonical `person_id` | `p1` |
| ETL Scheduler / Orchestrator | Triggers collection runs on schedule | `p2` |

---

## 11. Assumptions

- The Bitbucket Server instance is accessible from the connector's deployment environment over HTTPS.
- The provided credentials have read access to all configured projects and repositories.
- The Bitbucket Server REST API v1.0 is available and stable on the target instance (Bitbucket Server 6.x+ or Data Center).
- The Identity Manager is operational and reachable during collection runs.
- The unified `git_*` Silver tables are pre-provisioned per the schema in `docs/components/connectors/git/README.md`.
- Author emails in Bitbucket commits are corporate email addresses resolvable by the Identity Manager.

---

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Bitbucket Server instance not accessible (network, firewall) | Collection fails entirely | Fail-fast with clear error message; operational runbook for network configuration |
| API credentials expire or are revoked | Collection fails with 401/403 | Alert on auth failures; document credential rotation procedure |
| Large repositories with deep commit history cause slow initial collection | First run takes hours | Support configurable history depth limit for initial collection; document expected run times |
| Bitbucket API rate limiting enforced by organization | Throttled or blocked requests | Configurable inter-request delay + exponential backoff; default conservative settings |
| Author email absent from Bitbucket commits | Identity resolution falls back to username only | Document fallback behavior; flag unresolved identities for manual review |
| `bitbucket_api_cache` table grows unbounded | Storage pressure | Implement configurable TTL + periodic purge (see OQ-BB-2) |

---

## 13. Open Questions

### OQ-BB-1: Author name format handling

Bitbucket author names frequently use dot-separated corporate format (e.g., `John.Smith`) while GitHub uses various formats (`johndoe`, `John Doe`).

**Question**: Should the connector normalize author names during Silver-layer mapping, or preserve the raw Bitbucket format and delegate normalization to Gold-layer identity resolution?

**Current approach**: Preserve as-is in Silver; normalize in Gold identity resolution.

**Consideration**: Dot-separated names may be a corporate standard; normalizing early could lose information useful for matching across systems.

---

### OQ-BB-2: API cache retention policy

The optional `bitbucket_api_cache` Bronze table can grow unbounded without a retention policy.

**Question**: What is the recommended retention period for cached API responses?

**Options**:
1. Short TTL (1–4 hours) for volatile data (commits, PRs)
2. Long TTL (24 hours) for stable data (repositories, branches)
3. Event-based invalidation (webhook triggers)
4. Periodic purge (delete entries older than 7 days)

**Current approach**: No automatic expiration — manual cache management required.

---

### OQ-BB-3: Participant vs Reviewer distinction

Bitbucket distinguishes between formally assigned reviewers and participants (users who commented or otherwise interacted with a PR).

**Question**: Should the schema include a separate participant tracking table, or should participant roles be merged into the reviewer table using a `role` discriminator field?

**Current approach**: Only formal reviewers are stored in `git_pull_requests_reviewers`; participants are implicit from `git_pull_requests_comments.author_name`.

**Consideration**: Explicit participant data supports collaboration graph analytics but may duplicate comment-author data already present in the comments table.


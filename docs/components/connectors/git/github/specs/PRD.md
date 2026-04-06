# PRD — GitHub Connector

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
  - [5.5 Per-File Enrichment](#55-per-file-enrichment)
  - [5.6 Identity Resolution](#56-identity-resolution)
  - [5.7 Incremental Collection](#57-incremental-collection)
  - [5.8 Fault Tolerance and Resilience](#58-fault-tolerance-and-resilience)
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
  - [OQ-GH-1: Email privacy handling](#oq-gh-1-email-privacy-handling)
  - [OQ-GH-2: Review state mapping](#oq-gh-2-review-state-mapping)

<!-- /toc -->

---

## 1. Overview

### 1.1 Purpose

The GitHub connector collects version control data — repositories, branches, commits, pull requests, reviews, and comments — from GitHub organizations and repositories via the GitHub API. It integrates into the unified git pipeline, enabling cross-platform analytics alongside Bitbucket and GitLab data.

In addition to core version control data, the connector supports a per-file enrichment capability: it records extended properties for each changed file in a commit, enabling downstream AI detection and license scanning pipelines to attach their results to individual files without altering the core collection schema.

### 1.2 Background / Problem Statement

Organizations using GitHub as their primary version control platform require the same engineering analytics as teams on Bitbucket or GitLab: contributor throughput, pull request cycle times, reviewer participation, and language-level productivity breakdowns. Without a GitHub connector, GitHub-hosted projects are absent from platform-wide reports.

A growing need has also emerged for per-file third-party code detection: identifying files within commits that contain vendored libraries, copy-pasted open-source code, or AI-generated content that originated from external sources. Engineering compliance and AI adoption programs require this signal at the individual file level, not only at the commit level. The enrichment design must allow AI detection and license scanning pipelines to attach their results per file without coupling those pipelines to the core data collection process.

### 1.3 Goals (Business Outcomes)

**Baseline**: No GitHub data is currently collected (greenfield). All targets apply from v1.0 GA.

- Collect all repositories, branches, commits, pull requests, reviewer actions, and comments from GitHub organizations. **Target**: complete initial collection of an organization with up to 500 repositories within 8 hours under standard GitHub rate limit conditions.
- Store collected data in the unified `git_*` Silver tables using `data_source = "insight_github"` as the discriminator, enabling cross-platform queries alongside Bitbucket and GitLab data.
- Support incremental collection so that repeated runs only fetch data changed since the last successful run. **Target**: incremental runs for repositories with fewer than 10,000 commits per branch complete within 15 minutes under normal rate limit conditions.
- Resolve GitHub user identities (email, username) to canonical `person_id` via the Identity Manager, enabling cross-platform person analytics. **Target**: ≥ 95% `person_id` match rate for commits where a non-masked email address is present.
- Enable external enrichment pipelines (AI detection, license scanning) to attach per-file analysis results to collected commit files without modifying the core collection schema.
- Tolerate API errors, deleted resources, rate limiting, and temporary outages without losing collection progress. **Target**: a collection run that encounters non-fatal errors on up to 5% of repositories MUST still complete and record a `completed_with_errors` status rather than halting.

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Organization | GitHub organizational account grouping repositories; identified by a login name (e.g., `myorg`) |
| Repository | A git repository within an organization or user account, identified by `owner/name` (e.g., `myorg/my-repo`) |
| Pull Request (PR) | A code review request in GitHub, identified by a numeric `pr_number` within a repository |
| Review | A formal review submission on a GitHub PR: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, or `DISMISSED` |
| Draft PR | A pull request marked as work-in-progress; GitHub-specific concept not present in Bitbucket |
| `data_source` | Discriminator field in all unified `git_*` tables; value for this connector is `"insight_github"` |
| `person_id` | Canonical cross-system person identifier resolved by the Identity Manager |
| Per-file enrichment | Optional attachment of analysis results (AI detection, license scanning) to individual commit files |
| AI detection | Automated analysis to determine whether a file contains AI-generated or AI-assisted code |
| License scanning | Automated analysis to identify third-party licenses and copyright notices within a file |
| Incremental sync | Collection mode where only new or updated records are fetched, based on cursor state |
| PAT | Personal Access Token — one of the supported authentication methods |
| OAuth Token | OAuth app token issued by GitHub — functionally equivalent to a PAT for read-only API access; used when the organization enforces OAuth app authorization policies |
| GraphQL | GitHub's API v4 query language, providing efficient bulk data access |

---

## 2. Actors

### 2.1 Human Actors

#### Platform / Data Engineer

**ID**: `cpt-insightspec-actor-gh-platform-engineer`

**Role**: Deploys and operates the GitHub connector; configures credentials, organization scope, and schedule.
**Needs**: Clear configuration interface, visibility into collection status and errors, ability to re-run failed collections without data loss or duplication.

#### Analytics Engineer

**ID**: `cpt-insightspec-actor-gh-analytics-eng`

**Role**: Consumes unified `git_*` Silver tables to build Gold-layer analytics, reports, and dashboards.
**Needs**: GitHub data in the same schema as Bitbucket/GitLab data; GitHub-specific review states (`CHANGES_REQUESTED`, `DISMISSED`) to be correctly represented; per-file enrichment results to be queryable alongside core commit file data.

#### AI / Compliance Pipeline Operator

**ID**: `cpt-insightspec-actor-gh-enrichment-operator`

**Role**: Operates downstream pipelines (AI detection, license scanning) that analyze collected commit files and write enrichment results per file.
**Needs**: A stable, well-defined target table for per-file enrichment results that is independent of the core collection schedule; clear join keys between enrichment results and core commit file records.

#### Engineering Manager / Director

**ID**: `cpt-insightspec-actor-gh-eng-manager`

**Role**: Consumes Gold-layer reports that aggregate GitHub activity alongside other platforms.
**Needs**: Accurate contributor attribution, PR cycle time metrics, review participation data, and AI adoption metrics that reflect GitHub team activity.

### 2.2 System Actors

#### GitHub REST API v3 / GraphQL API v4

**ID**: `cpt-insightspec-actor-gh-api`

**Role**: Source system — provides organization, repository, branch, commit, pull request, and review data via REST and GraphQL APIs.

#### Identity Manager

**ID**: `cpt-insightspec-actor-gh-identity-manager`

**Role**: Resolves GitHub user emails and usernames to canonical `person_id` values for cross-platform identity unification.

#### ETL Scheduler / Orchestrator

**ID**: `cpt-insightspec-actor-gh-scheduler`

**Role**: Triggers connector runs on a configured schedule and monitors collection run outcomes.

#### AI Detection Pipeline

**ID**: `cpt-insightspec-actor-gh-ai-pipeline`

**Role**: Downstream enrichment pipeline that analyzes collected commit files for AI-generated or AI-assisted content and writes per-file flags to the enrichment table.

#### License Scanning Pipeline

**ID**: `cpt-insightspec-actor-gh-scancode-pipeline`

**Role**: Downstream enrichment pipeline that runs license and copyright scanning on collected commit files and writes per-file results to the enrichment table.

---

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires outbound HTTPS access to `api.github.com`.
- Authentication credentials (PAT or GitHub App token) must be provisioned with read access to all target organizations and repositories.
- The connector operates in batch pull mode; it does not require an inbound network port or webhook endpoint.
- The per-file enrichment table is populated by separate enrichment pipelines, not by the core connector. These pipelines must have write access to the enrichment table and read access to the core commit files table.
- GitHub enforces rate limits (5,000 requests/hour for authenticated REST; 5,000 points/hour for GraphQL). The connector must operate within these limits.

---

## 4. Scope

### 4.1 In Scope

- Discovery and collection of all accessible GitHub organizations and repositories.
- Collection of all branches per repository.
- Incremental collection of commit history per branch.
- Collection of per-file line change statistics for each commit.
- Collection of pull requests across all states (open, merged, closed), including draft PR flag.
- Collection of PR reviews, including GitHub's four formal review states (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`).
- Collection of PR comments (general discussion and inline code review comments).
- Collection of PR-to-commit linkage.
- Extraction of ticket references (e.g., Jira issue keys, GitHub issue numbers) from PR titles, descriptions, and commit messages.
- Incremental collection strategy: only fetch data changed since the last run.
- Checkpoint-based fault tolerance: save progress after each repository, support resume on failure.
- Identity resolution for commit authors and PR reviewers via the Identity Manager.
- A per-file enrichment table that external pipelines (AI detection, license scanning) can populate with analysis results for each collected commit file.

### 4.2 Out of Scope

- GitHub Actions / CI pipeline data collection.
- Collection of GitHub Issues, Projects, or Wikis.
- Collection of GitHub Packages or Releases.
- Collection of access control and permission data.
- Webhook-based real-time ingestion (batch pull only in this version).
- Gold-layer transformations (owned by analytics pipeline, not this connector).
- Execution of AI detection or license scanning (owned by dedicated enrichment pipelines).
- GitHub Enterprise Server with non-standard API endpoints (standard GitHub.com API only in this version).
- Commit-level enrichment properties (`git_commits_ext`) — populated by external AI/analysis pipelines independently of this connector, using the same EAV pattern as file-level enrichment.
- PR-level extended analytics properties (`git_pull_requests_ext`) — cycle time and review metric calculations are owned by the Gold-layer analytics pipeline, not this connector.

---

## 5. Functional Requirements

### 5.1 Repository Discovery

#### Discover Organizations and Repositories

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-discover-repos`

The connector MUST enumerate all accessible repositories within configured GitHub organizations and record repository metadata (name, owner login, default branch, visibility, language, size, timestamps) in the unified repository table.

**Rationale**: Cross-platform analytics require a complete inventory of all repositories.

**Actors**: `cpt-insightspec-actor-gh-platform-engineer`, `cpt-insightspec-actor-gh-api`

#### Collect Repository Extension Properties

- [ ] `p2` - **ID**: `cpt-insightspec-fr-gh-collect-repo-ext`

The connector SHOULD collect GitHub-specific repository metrics (stars count, forks count, watchers count, open issues count, fork status, archive status, default branch name) and store them in the unified repository extension table alongside the core repository record.

**Rationale**: GitHub provides richer repository metadata than other git platforms. Storing these metrics in the extension table enables analytics on repository health, popularity, and activity without modifying the unified core schema shared across platforms.

**Actors**: `cpt-insightspec-actor-gh-analytics-eng`

#### Discover Branches

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-discover-branches`

The connector MUST enumerate all branches per repository and track branch state to support incremental commit collection.

**Rationale**: Branch enumeration is a prerequisite for per-branch incremental commit collection and enables analytics on branch activity patterns.

**Actors**: `cpt-insightspec-actor-gh-api`

### 5.2 Commit Collection

#### Collect Commit History

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-collect-commits`

The connector MUST collect the full commit history for each branch, including author name, author email, author GitHub login, committer name, committer email, commit message, timestamp, and parent commit references. When a commit appears in more than one branch, the connector MUST store it once, attributed to the first branch in which it was encountered, to prevent duplicate contribution metrics.

**Rationale**: Commit history is the primary signal for contributor activity analytics.

**Actors**: `cpt-insightspec-actor-gh-platform-engineer`, `cpt-insightspec-actor-gh-api`

#### Collect Per-File Line Changes

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-collect-commit-files`

The connector MUST collect per-file line change statistics (file path, file extension, change type: added/modified/removed/renamed, lines added, lines removed) for each commit and store them in the unified commit files table.

**Rationale**: File-level data enables code churn analysis, language breakdown, and hotspot detection. It also provides the anchor records that downstream enrichment pipelines target.

**Actors**: `cpt-insightspec-actor-gh-analytics-eng`, `cpt-insightspec-actor-gh-api`

#### Detect Merge Commits

- [ ] `p2` - **ID**: `cpt-insightspec-fr-gh-detect-merge-commits`

The connector MUST identify and flag merge commits (commits with more than one parent) so they can be excluded from or weighted appropriately in contribution metrics.

**Actors**: `cpt-insightspec-actor-gh-analytics-eng`

### 5.3 Pull Request Collection

#### Collect Pull Request Metadata

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-collect-prs`

The connector MUST collect all pull requests across all states (open, merged, closed), including title, description, author, source branch, destination branch, state, timestamps (created, updated, closed), merge commit reference, and draft PR flag.

**Actors**: `cpt-insightspec-actor-gh-eng-manager`, `cpt-insightspec-actor-gh-api`

#### Collect PR Statistics

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-collect-pr-stats`

The connector MUST populate PR-level statistics: commit count, comment count, and file-level change counts (files changed, lines added, lines removed).

**Rationale**: PR size and comment volume are key inputs to cycle time and review quality metrics.

**Actors**: `cpt-insightspec-actor-gh-analytics-eng`

#### Extract Ticket References

- [ ] `p2` - **ID**: `cpt-insightspec-fr-gh-extract-tickets`

The connector MUST extract ticket references (e.g., Jira issue keys, GitHub issue numbers) from PR titles, descriptions, and commit messages and store them in the ticket references table. Extraction timing and implementation details are specified in [DESIGN.md](./DESIGN.md).

**Actors**: `cpt-insightspec-actor-gh-analytics-eng`

#### Collect PR-to-Commit Linkage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-pr-commits`

The connector MUST collect the set of commits associated with each pull request.

**Rationale**: PR-to-commit linkage is required for cycle time analysis, review scope assessment, and tracing individual commits to the PR workflow that introduced them.

**Actors**: `cpt-insightspec-actor-gh-analytics-eng`

### 5.4 Review and Comment Collection

#### Collect Reviewer Assignments and Review Actions

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-collect-reviewers`

The connector MUST collect formal review submissions for each pull request, including reviewer identity, review state (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`), and review timestamp.

**Rationale**: Reviewer participation and review quality are key metrics for engineering team process analytics.

**Actors**: `cpt-insightspec-actor-gh-eng-manager`, `cpt-insightspec-actor-gh-api`

#### Collect PR Comments

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-collect-comments`

The connector MUST collect all PR comments (both general discussion and inline code review comments), including comment author, content, creation and update timestamps, and inline anchor (file path and line number where applicable).

**Actors**: `cpt-insightspec-actor-gh-analytics-eng`

### 5.5 Per-File Enrichment

#### Maintain Per-File Enrichment Table

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-commit-files-ext`

The system MUST maintain a per-file enrichment table that stores extended analysis results for individual files within commits, using the same key-value structure as commit-level enrichment. Downstream pipelines MUST be able to write enrichment results per file independently of the core collection schedule.

**Rationale**: AI detection and license scanning pipelines operate asynchronously after collection is complete. Their results must be attached at the file level — not the commit level — to enable per-file compliance reporting and accurate third-party code attribution. The key-value design ensures the table can accommodate new analysis types without schema changes.

**Actors**: `cpt-insightspec-actor-gh-enrichment-operator`, `cpt-insightspec-actor-gh-ai-pipeline`, `cpt-insightspec-actor-gh-scancode-pipeline`, `cpt-insightspec-actor-gh-analytics-eng`

#### AI Third-Party Detection per File

- [ ] `p2` - **ID**: `cpt-insightspec-fr-gh-ai-thirdparty-flag`

The enrichment table MUST support recording whether an AI analysis pipeline has determined that a specific file within a commit contains third-party code not authored by the committer (such as vendored libraries or copy-pasted open-source code).

**Rationale**: Accurate AI adoption metrics require distinguishing AI-generated code from AI-assisted import or vendoring of third-party content.

**Actors**: `cpt-insightspec-actor-gh-ai-pipeline`, `cpt-insightspec-actor-gh-eng-manager`

#### License Scanner Third-Party Detection per File

- [ ] `p2` - **ID**: `cpt-insightspec-fr-gh-scancode-thirdparty-flag`

The enrichment table MUST support recording whether a license scanning pipeline has identified third-party license headers or copyright notices within a specific file.

**Rationale**: License compliance programs require per-file evidence of third-party content, not only commit-level flags.

**Actors**: `cpt-insightspec-actor-gh-scancode-pipeline`, `cpt-insightspec-actor-gh-analytics-eng`

#### License Scanning Metadata per File

- [ ] `p2` - **ID**: `cpt-insightspec-fr-gh-scancode-metadata`

The enrichment table MUST support recording structured license and copyright scan output for each file, including detected licenses, copyright holders, and SPDX identifiers.

**Rationale**: Downstream compliance reports require the full scan evidence, not only a binary flag.

**Actors**: `cpt-insightspec-actor-gh-scancode-pipeline`, `cpt-insightspec-actor-gh-analytics-eng`

### 5.6 Identity Resolution

#### Resolve Author and Reviewer Identities

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-identity-resolution`

The connector MUST resolve commit authors and PR reviewers to canonical `person_id` values via the Identity Manager. Email address is the primary resolution key; GitHub username (`author_login`) is the fallback when email is absent or masked (e.g., GitHub no-reply addresses).

**Rationale**: Cross-platform analytics require all persons to be unified under a single canonical identity regardless of their source platform representation.

**Actors**: `cpt-insightspec-actor-gh-identity-manager`, `cpt-insightspec-actor-gh-analytics-eng`

### 5.7 Incremental Collection

#### Track Collection Cursors

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-incremental-cursors`

The connector MUST maintain per-branch commit cursors (last collected commit hash and timestamp) and per-repository PR cursors (last collected updated timestamp) to support incremental collection runs that only fetch new or changed data.

**Rationale**: Full re-collection of large repositories is prohibitively expensive; incremental runs must complete in reasonable time.

**Actors**: `cpt-insightspec-actor-gh-platform-engineer`

#### Early Exit on Stale Data

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-early-exit`

The connector MUST stop fetching commits for a branch when it encounters a commit already present in the collection state. The connector MUST stop fetching pull requests when it encounters a PR whose update timestamp is before the last collection cursor.

**Rationale**: Early exit avoids redundant API calls on incremental runs, significantly reducing rate limit consumption and run time for active repositories.

**Actors**: `cpt-insightspec-actor-gh-platform-engineer`

#### Configurable History Depth Limit

- [ ] `p2` - **ID**: `cpt-insightspec-fr-gh-history-depth`

The connector MUST support a configurable `history_since_date` parameter that limits commit collection to commits authored on or after a specified date. When set, the first full collection run MUST NOT fetch commits older than this date. Subsequent incremental runs are unaffected and continue from the stored cursor.

**Rationale**: Large repositories with years of history can result in initial collection runs that exceed acceptable time budgets. A configurable date cutoff provides a practical onboarding escape hatch and keeps initial runs predictable.

**Actors**: `cpt-insightspec-actor-gh-platform-engineer`

### 5.8 Fault Tolerance and Resilience

#### Retry on Transient Errors

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-retry`

The connector MUST retry API calls that fail with transient errors (HTTP 429, 500, 502, 503) using exponential backoff. The maximum number of retries and base delay MUST be configurable.

**Actors**: `cpt-insightspec-actor-gh-platform-engineer`

#### Continue on Non-Fatal Errors

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-continue-on-error`

The connector MUST continue collection when individual items fail with non-fatal errors (HTTP 404 for deleted resources, malformed API responses). It MUST log the error, skip the affected item, and continue with the next item.

**Actors**: `cpt-insightspec-actor-gh-platform-engineer`

#### Checkpoint and Resume

- [ ] `p1` - **ID**: `cpt-insightspec-fr-gh-checkpoint`

The connector MUST checkpoint its progress after completing each repository so that a failed run can be resumed from the last successful checkpoint rather than restarting from the beginning.

**Actors**: `cpt-insightspec-actor-gh-platform-engineer`

---

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Authentication Flexibility

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-gh-auth`

The connector MUST support Personal Access Token (PAT), GitHub App installation token, and OAuth app token authentication methods, configurable without code changes. OAuth app tokens are functionally equivalent to PATs for read-only API access and MUST be accepted wherever PATs are accepted.

#### Rate Limit Compliance

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-gh-rate-limiting`

The connector MUST operate within GitHub's API rate limits. It MUST implement exponential backoff on HTTP 429 responses and MUST respect the `X-RateLimit-Reset` header to schedule retries after the rate limit window resets.

**Threshold**: Default inter-request delay configurable; page size configurable up to platform maximum.

#### Unified Schema Compliance

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-gh-schema-compliance`

All collected data MUST be stored in the unified `git_*` tables defined in `docs/components/connectors/git/README.md`. The connector MUST NOT create GitHub-specific analytics tables. Storage layering details are specified in [DESIGN.md](./DESIGN.md).

#### Data Source Discriminator

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-gh-data-source`

All rows written to unified tables MUST carry `data_source = "insight_github"` to enable source-level filtering and deduplication in cross-platform queries.

#### Idempotent Writes

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-gh-idempotent`

Repeated collection of the same data MUST NOT create duplicate rows. The connector MUST use upsert semantics (keyed on natural primary keys) for all write operations.

### 6.2 NFR Exclusions

- **Real-time latency SLA**: Not applicable — the connector operates in scheduled batch pull mode only.
- **GPU / high-compute NFRs**: Not applicable — the connector performs I/O-bound API collection with no computational requirements.
- **Enrichment pipeline execution SLA**: Not applicable — enrichment pipelines (AI detection, license scanning) have their own operational requirements independent of this connector.
- **Safety (SAFE)**: Not applicable — this connector is a data collection pipeline with no physical or safety-critical interactions.
- **Usability / UX**: Not applicable — the connector exposes a CLI and programmatic interface for platform engineers; end-user accessibility standards do not apply.
- **Availability / Reliability SLA (REL)**: Not applicable — the connector is a scheduled batch job; availability SLAs apply to the scheduling infrastructure, not to the connector itself.
- **Regulatory compliance (COMPL)**: Not applicable — the connector collects code metadata (commit messages, file names, line counts) from internal GitHub organizations; no PII, healthcare, or financial data is in scope.
- **Maintainability documentation (MAINT)**: Not applicable — API and admin documentation requirements are owned by the platform-level PRD.
- **Operations (OPS)**: Not applicable — deployment and monitoring requirements are owned by the platform infrastructure team.

---

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Connector Entry Point

- [ ] `p1` - **ID**: `cpt-insightspec-interface-gh-entrypoint`

**Type**: Source connector

**Stability**: stable

**Description**: The connector implements a standard source protocol (`check`, `discover`, `read`) and runs as an isolated container managed by the orchestrator. Configuration (organization scope, credentials, schedule parameters) is provided via connection settings. Implementation technology details are specified in [DESIGN.md](./DESIGN.md).

**Breaking Change Policy**: Configuration schema changes require a version bump and migration guide.

### 7.2 External Integration Contracts

#### GitHub API Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-gh-api`

**Direction**: required from client (GitHub.com)

**Protocol/Format**: HTTP/REST JSON (v3) and GraphQL (v4)

**Compatibility**: GitHub REST API v3 and GraphQL API v4; no backwards-incompatible breaking changes expected within standard GitHub.com

#### Identity Manager Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-gh-identity-mgr`

**Direction**: required from client (Identity Manager service)

**Protocol/Format**: Internal service call; input is email + name + source label; output is canonical `person_id`

**Compatibility**: Identity Manager must be available and responsive during collection runs

#### Per-File Enrichment Table Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-gh-file-enrichment`

**Direction**: provided to enrichment pipelines

**Protocol/Format**: Direct table writes; join key is `(project_key, repo_slug, commit_hash, file_path, data_source)`

**Schema reference**: `docs/components/connectors/git/README.md` → `git_commits_files_ext`

**Compatibility**: Enrichment pipelines depend on the `git_commits_files_ext` table structure; changes to join key columns are breaking.

---

## 8. Use Cases

#### Full Initial Collection

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-gh-initial-collection`

**Actor**: `cpt-insightspec-actor-gh-platform-engineer`

**Preconditions**:
- Connector is configured with valid GitHub credentials and organization scope.
- No prior collection state exists.

**Main Flow**:
1. Platform Engineer triggers the connector run.
2. Connector enumerates all configured organizations and their repositories.
3. For each repository: collect branches, then all commits per branch (full history), then all PRs with reviews, comments, and file changes.
4. Connector writes all data to unified `git_*` Silver tables with `data_source = "insight_github"`.
5. Connector records the completed run in the collection runs log.

**Postconditions**:
- All repositories, commits, PRs, reviews, and comments are present in the Silver tables.
- Commit file records are available as anchor rows for downstream enrichment pipelines.
- Collection run log shows `status = completed`.

**Alternative Flows**:
- **Authentication failure**: Connector halts and logs error; operator is notified.
- **Rate limit exceeded**: Connector backs off and resumes after reset window.
- **Repository deleted mid-run**: HTTP 404 is logged as a warning; collection continues with the next repository.

#### Incremental Collection Run

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-gh-incremental`

**Actor**: `cpt-insightspec-actor-gh-scheduler`

**Preconditions**:
- At least one prior successful collection run exists.
- Branch-level commit cursors and PR update timestamps are stored.

**Main Flow**:
1. Scheduler triggers connector run on configured schedule.
2. Connector reads cursors from Silver tables.
3. For each branch: fetch commits only up to the last known commit hash; stop at cursor.
4. For PRs: fetch newest first; stop when update timestamp is before last cursor.
5. Write only new or changed records; skip unchanged items.
6. Update cursors for next run.

**Postconditions**:
- Only new or updated data is added to Silver tables.
- Run completes significantly faster than a full collection.

#### Enrichment Pipeline Attaches Per-File Results

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-gh-file-enrichment`

**Actor**: `cpt-insightspec-actor-gh-ai-pipeline`, `cpt-insightspec-actor-gh-scancode-pipeline`

**Preconditions**:
- At least one collection run has populated commit file records.
- Enrichment pipeline has write access to the per-file enrichment table.

**Main Flow**:
1. Enrichment pipeline reads commit file records from the unified commit files table.
2. Pipeline analyzes each file (AI detection or license scanning).
3. Pipeline writes analysis result (property key, value, type) per file to the per-file enrichment table, joining on `(project_key, repo_slug, commit_hash, file_path, data_source)`.
4. Analytics consumers query enrichment results alongside core commit file data.

**Postconditions**:
- Per-file enrichment results are available for compliance and AI adoption reporting.
- Core commit file records are unchanged.

---

## 9. Acceptance Criteria

- [ ] All repositories, branches, commits, PRs, reviews, and comments from a sample GitHub organization are present in the unified `git_*` Silver tables after a full collection run.
- [ ] `data_source = "insight_github"` is set on every row written by this connector.
- [ ] A second collection run (incremental) completes without creating duplicate rows.
- [ ] An incremental run fetches only data updated since the last run.
- [ ] GitHub PR reviews are stored with correct state values (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`).
- [ ] Draft PR flag is correctly captured.
- [ ] Collection continues and completes when one repository returns 404 or one PR returns a malformed response.
- [ ] Identity resolution populates `person_id` for all commit authors and reviewers with a matching email in the Identity Manager.
- [ ] An enrichment pipeline can write per-file AI and license scan results to the per-file enrichment table and those results are queryable alongside core commit file data.

---

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| GitHub REST API v3 / GraphQL API v4 | Source data — all collected data originates from these APIs | `p1` |
| Unified `git_*` Silver tables | Target schema defined in `docs/components/connectors/git/README.md` | `p1` |
| Identity Manager | Resolves author emails and usernames to canonical `person_id` | `p1` |
| ETL Scheduler / Orchestrator | Triggers collection runs on schedule | `p2` |
| AI Detection Pipeline | Writes per-file AI analysis results to `git_commits_files_ext` | `p2` |
| License Scanning Pipeline | Writes per-file scan results to `git_commits_files_ext` | `p2` |

---

## 11. Assumptions

- The GitHub.com API is accessible from the connector's deployment environment over HTTPS.
- The provided credentials have read access to all configured organizations and repositories.
- The Identity Manager is operational and reachable during collection runs.
- The unified `git_*` Silver tables (including `git_commits_files_ext`) are pre-provisioned per the schema in `docs/components/connectors/git/README.md`.
- GitHub's no-reply email addresses (`user@users.noreply.github.com`) are resolved by the Identity Manager via the username fallback.
- Enrichment pipelines operate independently of the core connector and are responsible for their own scheduling and error handling.
- Data retention, archival, and lifecycle management (purging) for collected data are owned by the platform-level data governance policy and are out of scope for this connector.

---

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| GitHub API rate limiting | Collection slows or stalls for large organizations | GraphQL bulk queries reduce call count; configurable backoff; rate limit header inspection |
| Email privacy masking (no-reply addresses) | Identity resolution falls back to username only | Document fallback behavior; flag unresolved identities for manual review |
| Large repositories with deep commit history | First run takes hours | Support configurable history depth limit; document expected run times |
| API credentials expire or are revoked | Collection fails with 401/403 | Alert on auth failures; document credential rotation procedure |
| Enrichment pipelines write stale or duplicate results | Incorrect per-file flags in compliance reports | Enrichment table uses upsert semantics; `collected_at` timestamp enables staleness detection |

---

## 13. Open Questions

### OQ-GH-1: Email privacy handling

**Status**: Resolved (Owner: Platform Engineering, Resolved: 2026-03)

The connector stores raw author identity fields (email, login, database ID) on commit records. Identity resolution is delegated to the Identity Manager, using email as primary key and GitHub login as fallback. No-reply addresses are handled by the fallback path. For reviews and comments, email is not available — identity resolution uses login and database ID. Implementation details are specified in [DESIGN.md](./DESIGN.md).

---

### OQ-GH-2: Review state mapping

**Status**: Resolved (Owner: Platform Engineering, Resolved: 2026-03)

All four formal review states (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`) are persisted. `PENDING` reviews (draft reviews not yet formally submitted) are skipped — they are not collected. Analytics consumers filter by state as needed.

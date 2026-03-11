---
cypilot: true
type: project-rule
topic: architecture
generated-by: auto-config
version: 1.0
---

# Architecture

Data pipeline architecture and source categorisation rules for Constructor Insight. Apply when modifying pipeline architecture, adding new sources, or refactoring Bronze/Silver/Gold layers.

<!-- toc -->

- [Bronze / Silver / Gold Layers](#bronze-silver-gold-layers)
- [Identity Resolution](#identity-resolution)
- [Source Categories](#source-categories)
- [Collection Run Tables](#collection-run-tables)
- [Critical Files](#critical-files)

<!-- /toc -->

## Bronze / Silver / Gold Layers

**Bronze** — raw tables per source. One row per API object. Use source-native schema and IDs. Naming: `{source}_{entity}`.

Evidence: `docs/CONNECTORS_REFERENCE.md:10–18`

**Silver step 1** — `class_{domain}` tables, unified schema, source-native user IDs still present. Produced by the cross-source unification job.

Evidence: `docs/CONNECTORS_REFERENCE.md:20–27`

**Silver step 2** — same `class_{domain}` table names, same unified schema, but `person_id` replaces source-native user IDs. Produced by a separate identity resolution job.

Evidence: `docs/CONNECTORS_REFERENCE.md:28–33`

**Gold** — derived metrics, no raw events. Use domain-specific names without layer prefix — e.g. `status_periods`, `throughput`, `wip_snapshots`.

Evidence: `docs/CONNECTORS_REFERENCE.md:35–40`

## Identity Resolution

The Identity Manager is a PostgreSQL/MariaDB service that maps source-native user identifiers to a canonical `person_id`.

Sources for identity: email, username, employee_id, git login, and similar fields collected by HR connectors.

HR connectors (BambooHR, Workday, LDAP/AD) feed the Identity Manager directly alongside their Bronze tables.

Evidence: `docs/CONNECTORS_REFERENCE.md:22–26` — Identity Manager diagram.

## Source Categories

Seven source categories currently defined:

| Category | Examples |
|----------|---------|
| Version Control | GitHub, Bitbucket, GitLab |
| Task Tracking | YouTrack, Jira |
| Communication | Microsoft 365, Zulip |
| AI Dev Tool | Cursor, Windsurf, GitHub Copilot |
| AI Tool | Claude API, Claude Team, OpenAI API, ChatGPT Team |
| HR | BambooHR, Workday, LDAP/AD |
| CRM | HubSpot, Salesforce |
| Quality / Testing | Allure TestOps |

Evidence: section headings throughout `docs/CONNECTORS_REFERENCE.md`.

## Collection Run Tables

Every source has exactly one `{source}_collection_runs` table as its final Bronze table. This is a monitoring table only — never an analytics source.

Fields: `run_id`, `started_at`, `completed_at`, `status` (`running`/`completed`/`failed`), counts per entity type, `api_calls`, `errors`, `settings`.

Evidence: `docs/CONNECTORS_REFERENCE.md:333–347` — `github_collection_runs`.

## Critical Files

| File | Why it matters |
|------|---------------|
| `docs/CONNECTORS_REFERENCE.md` | Single source of truth for all connector schemas, Bronze/Silver/Gold naming conventions, and the Identity Manager pipeline |

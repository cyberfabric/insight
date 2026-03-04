# Connector Specifications

> Version 1.0 — March 2026

Per-source deep-dive specifications for Constructor Insight connectors. Each file expands on the corresponding source in [`../CONNECTORS_REFERENCE.md`](../CONNECTORS_REFERENCE.md) with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Index](#index)
  - [Version Control](#version-control)
  - [Task Tracking](#task-tracking)
  - [Communication](#communication)
  - [AI Dev Tools](#ai-dev-tools)
  - [AI Tools](#ai-tools)
  - [HR / Directory](#hr-directory)
  - [CRM](#crm)
  - [Quality / Testing](#quality-testing)
- [Unified Streams](#unified-streams)
- [How to Use](#how-to-use)

<!-- /toc -->

---

## Index

### Version Control

| # | Source | Spec | Status |
|---|--------|------|--------|
| 1 | GitHub | [`github.md`](github.md) | ✓ Done |
| 2 | Bitbucket | [`bitbucket.md`](bitbucket.md) | ✓ Done |
| 3 | GitLab | [`gitlab.md`](gitlab.md) | ✓ Done |

### Task Tracking

| # | Source | Spec | Status |
|---|--------|------|--------|
| 4 | YouTrack | [`youtrack.md`](youtrack.md) | ✓ Done |
| 5 | Jira | [`jira.md`](jira.md) | ✓ Done |

### Communication

| # | Source | Spec | Status |
|---|--------|------|--------|
| 6 | Microsoft 365 | [`m365.md`](m365.md) | ✓ Done |
| 7 | Zulip | [`zulip.md`](zulip.md) | ✓ Done |

### AI Dev Tools

| # | Source | Spec | Status |
|---|--------|------|--------|
| 8 | Cursor | [`cursor.md`](cursor.md) | ✓ Done |
| 9 | Windsurf | [`windsurf.md`](windsurf.md) | ✓ Done |
| 15 | GitHub Copilot | [`github-copilot.md`](github-copilot.md) | ✓ Done |

### AI Tools

| # | Source | Spec | Status |
|---|--------|------|--------|
| 13 | Claude API | [`claude-api.md`](claude-api.md) | ✓ Done |
| 14 | Claude Team Plan | [`claude-team.md`](claude-team.md) | ✓ Done |
| 18 | OpenAI API | [`openai-api.md`](openai-api.md) | ✓ Done |
| 19 | ChatGPT Team | [`chatgpt-team.md`](chatgpt-team.md) | ✓ Done |

### HR / Directory

| # | Source | Spec | Status |
|---|--------|------|--------|
| 10 | BambooHR | [`bamboohr.md`](bamboohr.md) | ✓ Done |
| 11 | Workday | [`workday.md`](workday.md) | ✓ Done |
| 12 | LDAP / Active Directory | [`ldap.md`](ldap.md) | ✓ Done |

### CRM

| # | Source | Spec | Status |
|---|--------|------|--------|
| 16 | HubSpot | [`hubspot.md`](hubspot.md) | ✓ Done |
| 17 | Salesforce | [`salesforce.md`](salesforce.md) | ✓ Done |

### Quality / Testing

| # | Source | Spec | Status |
|---|--------|------|--------|
| 20 | Allure TestOps | [`allure.md`](allure.md) | ✓ Done |

---

## Unified Streams

| Stream | Sources | Spec |
|--------|---------|------|
| `class_communication_events` | M365 (Email + Teams) + Zulip | Documented in [`../CONNECTORS_REFERENCE.md`](../CONNECTORS_REFERENCE.md#unified-stream-1-classcommunicationevents) |
| Task Tracker (Silver → Gold) | YouTrack + Jira | Documented in [`../CONNECTORS_REFERENCE.md`](../CONNECTORS_REFERENCE.md#unified-stream-2-task-tracker-silver--gold) |

---

## How to Use

- **Main reference** — [`../CONNECTORS_REFERENCE.md`](../CONNECTORS_REFERENCE.md) is the canonical index of all Bronze table schemas and the Bronze → Silver → Gold pipeline overview.
- **Per-source specs** (this directory) — expand on individual sources with additional detail: complete field lists, API notes, identity mapping, Silver channel mappings, and open questions.
- **Generate a new spec** — `/cypilot-generate Connector spec for {Source Name}`

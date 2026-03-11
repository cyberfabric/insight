# Connector Specifications

> Version 1.0 — March 2026

Per-source deep-dive specifications for Constructor Insight connectors. Each file expands on the corresponding source in [`../CONNECTORS_REFERENCE.md`](../CONNECTORS_REFERENCE.md) with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Index](#index)
  - [Version Control](#version-control)
  - [Task Tracking](#task-tracking)
  - [Collaboration](#collaboration)
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

| Source | Spec | Status |
|--------|------|--------|
| Git (unified schema) | [`git/README.md`](git/README.md) | Draft |
| GitHub | [`git/github.md`](git/github.md) | Draft |
| Bitbucket | [`git/bitbucket.md`](git/bitbucket.md) | Draft |
| GitLab | [`git/gitlab.md`](git/gitlab.md) | Draft |

### Task Tracking

| Source | Spec | Status |
|--------|------|--------|
| Task Tracking (unified schema) | [`task-tracking/README.md`](task-tracking/README.md) | Draft |
| YouTrack | [`task-tracking/youtrack.md`](task-tracking/youtrack.md) | Proposed |
| Jira | [`task-tracking/jira.md`](task-tracking/jira.md) | Proposed |

### Collaboration

| Source | Spec | Status |
|--------|------|--------|
| Collaboration (unified schema) | [`collaboration/README.md`](collaboration/README.md) | Draft |
| Microsoft 365 | [`collaboration/m365.md`](collaboration/m365.md) | Proposed |
| Zulip | [`collaboration/zulip.md`](collaboration/zulip.md) | Proposed |
| Slack | [`collaboration/slack.md`](collaboration/slack.md) | Draft |

### AI Dev Tools

| Source | Spec | Status |
|--------|------|--------|
| Cursor | [`ai-dev/cursor.md`](ai-dev/cursor.md) | Proposed |
| Windsurf | [`ai-dev/windsurf.md`](ai-dev/windsurf.md) | Proposed |
| GitHub Copilot | [`ai-dev/github-copilot.md`](ai-dev/github-copilot.md) | Proposed |

### AI Tools

| Source | Spec | Status |
|--------|------|--------|
| Claude API | [`ai/claude-api.md`](ai/claude-api.md) | Proposed |
| Claude Team Plan | [`ai/claude-team.md`](ai/claude-team.md) | Proposed |
| OpenAI API | [`ai/openai-api.md`](ai/openai-api.md) | Proposed |
| ChatGPT Team | [`ai/chatgpt-team.md`](ai/chatgpt-team.md) | Proposed |

### HR / Directory

| Source | Spec | Status |
|--------|------|--------|
| BambooHR | [`hr-directory/bamboohr.md`](hr-directory/bamboohr.md) | Proposed |
| Workday | [`hr-directory/workday.md`](hr-directory/workday.md) | Proposed |
| LDAP / Active Directory | [`hr-directory/ldap.md`](hr-directory/ldap.md) | Proposed |

### CRM

| Source | Spec | Status |
|--------|------|--------|
| HubSpot | [`crm/hubspot.md`](crm/hubspot.md) | Proposed |
| Salesforce | [`crm/salesforce.md`](crm/salesforce.md) | Proposed |

### Wiki

| Source | Spec | Status |
|--------|------|--------|
| Wiki (unified schema) | [`wiki/README.md`](wiki/README.md) | Draft |
| Confluence | [`wiki/confluence.md`](wiki/confluence.md) | Draft |
| Outline | [`wiki/outline.md`](wiki/outline.md) | Draft |

### Quality / Testing

| Source | Spec | Status |
|--------|------|--------|
| Allure TestOps | [`allure.md`](allure.md) | Proposed |

---

## Unified Streams

| Stream | Sources | Spec |
|--------|---------|------|
| `class_communication_metrics` | M365 (Email + Teams) + Zulip + Slack | [`collaboration/README.md`](collaboration/README.md) |
| `class_document_metrics` | M365 (OneDrive + SharePoint) | [`collaboration/README.md`](collaboration/README.md) — planned |
| Task Tracker unified schema | YouTrack + Jira | [`task-tracking/README.md`](task-tracking/README.md) |
| `class_wiki_pages` | Confluence + Outline | [`wiki/README.md`](wiki/README.md) — draft |
| `class_wiki_activity` | Confluence + Outline | [`wiki/README.md`](wiki/README.md) — draft |

---

## How to Use

- **Main reference** — [`../CONNECTORS_REFERENCE.md`](../CONNECTORS_REFERENCE.md) is the canonical index of all Bronze table schemas and the Bronze → Silver → Gold pipeline overview.
- **Per-source specs** (this directory) — expand on individual sources with additional detail: complete field lists, API notes, identity mapping, Silver channel mappings, and open questions.
- **Generate a new spec** — `/cypilot-generate Connector spec for {Source Name}`

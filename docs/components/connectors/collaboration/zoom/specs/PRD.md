# PRD — Zoom Connector

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
  - [5.1 Meeting Discovery and Enrichment](#51-meeting-discovery-and-enrichment)
  - [5.2 Chat and Message Activity](#52-chat-and-message-activity)
  - [5.3 Connector Operations and Data Integrity](#53-connector-operations-and-data-integrity)
  - [5.4 Identity and Directory Support](#54-identity-and-directory-support)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
  - [UC-001 Collect Newly Discovered Meetings](#uc-001-collect-newly-discovered-meetings)
  - [UC-002 Collect Zoom Message Activity](#uc-002-collect-zoom-message-activity)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The Zoom Connector extracts collaboration activity from Zoom into the Insight platform's Bronze layer so the organization can understand which meetings happened, who attended them, how long participants stayed, and how actively users communicated through Zoom messages. The connector covers meetings as the primary collaboration signal, message activity as the primary async signal, and Zoom users only as supporting identity and directory context.

The connector is designed around incremental collection. Newly discovered meetings are not sufficient on their own; each newly discovered meeting must trigger collection of meeting details and participant records so that downstream analytics can measure real participation rather than only high-level summaries. Message activity is also required, but its collection path must follow source capabilities and should only be linked directly to meetings when Zoom exposes a reliable meeting-level relationship.

### 1.2 Background / Problem Statement

Zoom is a common collaboration platform for organizations that rely on scheduled meetings, ad hoc calls, and team messaging. Insight needs Zoom activity alongside Microsoft 365, Slack, and other collaboration sources to produce a complete view of communication patterns across the organization.

The existing Zoom connector reference is summary-oriented and useful for schema exploration, but the business need for Insight is more specific: the platform must know which meetings actually occurred, who participated in them, and how long each participant attended. Daily summary metrics alone are insufficient for this purpose because they do not provide durable per-meeting attendance evidence or participant-level duration.

Message activity is also required, but message content is not. The connector should support counts and activity attribution needed for collaboration analytics without turning Zoom into a content archiving system. Historical backfill is useful when available, but because source retention and account configuration may limit what can be recovered, backfill should be treated as best-effort while ongoing incremental collection remains mandatory.

**Target Users**:

- Platform operators who configure Zoom credentials, scopes, and collection schedules
- Data analysts who consume Zoom meeting and message activity in Silver and Gold layers
- Organization leaders who use participation and communication metrics to understand collaboration load

**Key Problems Solved**:

- Lack of per-meeting evidence showing which Zoom meetings occurred and who actually attended them
- Inability to measure participant attendance duration from summary-only datasets
- Missing Zoom message activity needed to compare synchronous and asynchronous collaboration behavior
- Risk of losing newly available meeting detail if discovery is not followed by immediate incremental enrichment
- Ambiguity about whether Zoom message metrics must always be tied to per-meeting enrichment even when the source exposes them more reliably through separate activity flows

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- Newly discovered Zoom meetings are enriched with meeting details and participant data within 24 hours of discovery for 95% of meetings over a 90-day period (Baseline: no Zoom connector; Target: v1.0)
- Participant-level attendance duration is available for at least 95% of collected meetings that expose participant detail through the configured Zoom account over a 90-day period (Baseline: unavailable; Target: v1.0)
- Per-user Zoom message activity counts are available for analyst use within 24 hours of source availability for 95% of collection days over a 90-day period (Baseline: unavailable; Target: v1.0)

**Capabilities**:

- Discover Zoom meetings and enrich each newly discovered meeting with detail and participants
- Measure who attended a meeting and how long each participant attended
- Collect Zoom message activity for user-level communication metrics without storing message content, using the most suitable source-supported collection path
- Support identity resolution through Zoom user directory data and stable source-native identifiers

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Zoom Meeting | A Zoom-hosted meeting session used as the primary synchronous collaboration object for this connector scope. |
| Meeting Discovery | The process of identifying a meeting that has occurred or become newly visible to the connector. |
| Meeting Enrichment | Follow-up collection for a discovered meeting, including meeting detail and participant records. |
| Participant Attendance Duration | The amount of time an identified participant was present in a specific meeting, derived from source-provided attendance detail. |
| Message Activity | Zoom chat or messaging events and counts attributed to users; excludes message body content in this PRD. |
| Historical Backfill | Best-effort retrieval of older Zoom activity that may still be available from the source at the time the connector is first configured. |

## 2. Actors

### 2.1 Human Actors

#### Platform Operator

**ID**: `cpt-insightspec-actor-zoom-operator`

**Role**: Configures Zoom application credentials, enables required scopes, selects collection settings, and monitors run health.
**Needs**: A connector that can continuously collect Zoom activity without manual intervention and clearly signal when source limitations or failures threaten data completeness.

#### Data Analyst

**ID**: `cpt-insightspec-actor-zoom-analyst`

**Role**: Uses Zoom meeting attendance and message activity data in Silver and Gold models for reporting, trend analysis, and cross-platform comparisons.
**Needs**: Reliable meeting-level and participant-level activity with enough identity context to join Zoom data to other collaboration sources.

#### Organization Leader

**ID**: `cpt-insightspec-actor-zoom-business-lead`

**Role**: Reviews collaboration metrics to understand meeting load, participation levels, and communication patterns across teams.
**Needs**: Trustworthy metrics about which meetings happened, who attended, how long they attended, and how actively people used Zoom messaging.

### 2.2 System Actors

#### Zoom API

**ID**: `cpt-insightspec-actor-zoom-api`

**Role**: External API provider for Zoom meetings, participants, users, and message-related activity. Enforces authentication, entitlement, retention, and rate limits.

#### Bronze Ingestion Platform

**ID**: `cpt-insightspec-actor-zoom-bronze-ingestion`

**Role**: Receives Zoom connector output, persists Bronze records, and exposes them for downstream identity resolution and analytics processing.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires a Zoom account configuration and application scopes that allow meeting discovery, participant access, user lookup, and message activity collection
- The connector operates as a batch collector, not a real-time event stream
- The connector MUST run frequently enough to preserve newly available meeting and message activity before source-side retention or visibility limits reduce completeness
- Historical backfill is best-effort and depends on source retention, account permissions, and endpoint availability at onboarding time

## 4. Scope

### 4.1 In Scope

- Discovery of Zoom meetings that occurred within the configured collection window
- Incremental enrichment of every newly discovered meeting with meeting details and participant records
- Participant-level attendance data sufficient to determine who attended and how long they attended
- Collection of Zoom message activity for all messages in supported Zoom messaging surfaces using source-capability-aware activity flows
- Collection of Zoom user records only as identity and directory support for meetings and messages
- Connector run logging, completeness monitoring, and idempotent reprocessing of overlapping collection windows

### 4.2 Out of Scope

- Zoom Phone and non-meeting telephony activity
- Webinar collection and webinar analytics in this release
- Message content storage, transcript storage, file attachment ingestion, or compliance archiving
- Recording media, captions, whiteboards, and other rich meeting artifacts
- Silver and Gold transformation logic outside the Bronze connector boundary
- Zoom as a source-of-truth employee directory beyond identity support needs

## 5. Functional Requirements

### 5.1 Meeting Discovery and Enrichment

#### Discover Zoom Meetings

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-meeting-discovery`

The connector **MUST** discover Zoom meetings that become newly visible within the configured collection window and persist source-native meeting identifiers, timestamps, organizer context, and meeting classification attributes required for downstream analysis.

**Rationale**: Insight cannot measure collaboration load from Zoom unless it has durable evidence of which meetings actually occurred.

**Actors**: `cpt-insightspec-actor-zoom-api`, `cpt-insightspec-actor-zoom-analyst`

#### Enrich Every Newly Discovered Meeting

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-meeting-enrichment`

For every newly discovered meeting, the connector **MUST** trigger incremental collection of meeting details and participant records within the same logical collection cycle or the next eligible follow-up cycle.

**Rationale**: Meeting discovery without immediate enrichment creates a risk that detailed evidence will be missing even when the meeting itself is known to have happened.

**Actors**: `cpt-insightspec-actor-zoom-api`, `cpt-insightspec-actor-zoom-operator`

#### Capture Meeting Participant Attendance

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-meeting-participants`

The connector **MUST** capture participant-level attendance for collected meetings, including enough source evidence to determine which participants attended each meeting and how long each participant attended.

**Rationale**: Participant attendance duration is a core business requirement for collaboration analysis and must not be reduced to user-day summary counts.

**Actors**: `cpt-insightspec-actor-zoom-api`, `cpt-insightspec-actor-zoom-analyst`, `cpt-insightspec-actor-zoom-business-lead`

#### Preserve Meeting-Level Traceability

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-meeting-traceability`

The connector **MUST** preserve stable meeting-level identifiers and relationships between meeting records and participant records, and it **SHOULD** preserve reliable links to related message activity when the source exposes such linkage.

**Rationale**: Downstream trust depends on the ability to explain how attendance and communication metrics were derived from source events.

**Actors**: `cpt-insightspec-actor-zoom-analyst`

### 5.2 Chat and Message Activity

#### Collect Zoom Message Activity

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-message-activity`

The connector **MUST** collect Zoom message activity for all supported messages in scope, attributing each message to a user and preserving the message-level metadata required to count user message volume over time.

**Rationale**: Insight needs Zoom async collaboration data to compare message behavior with meetings and with other collaboration platforms.

**Actors**: `cpt-insightspec-actor-zoom-api`, `cpt-insightspec-actor-zoom-analyst`

#### Use Source-Capability-Aware Message Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-message-collection-strategy`

If Zoom provides a suitable aggregated or direct activity endpoint for the required message metrics, the connector **MUST** use that source-supported path. If Zoom does not provide such an endpoint, the connector **MUST** still collect required message activity through separate message or chat collection flows.

**Rationale**: Message activity is mandatory, but the source may expose it through different collection patterns. The connector should use the most reliable supported path rather than forcing a single strategy.

**Actors**: `cpt-insightspec-actor-zoom-api`, `cpt-insightspec-actor-zoom-operator`

#### Do Not Force Meeting-Level Message Linkage

- [ ] `p2` - **ID**: `cpt-insightspec-fr-zoom-message-linkage-scope`

The connector **MUST NOT** require message activity to be collected through per-meeting enrichment unless the source provides a reliable meeting-level linkage. When such linkage is unavailable, the connector **MUST** collect message activity through the appropriate separate activity flow and preserve the strongest available attribution context.

**Rationale**: Some Zoom message metrics may be available without trustworthy meeting-level linkage. Forcing them into meeting enrichment would create avoidable gaps or misleading associations.

**Actors**: `cpt-insightspec-actor-zoom-api`, `cpt-insightspec-actor-zoom-analyst`

#### Exclude Message Content

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-message-content-exclusion`

The connector **MUST NOT** store Zoom message body content when satisfying message activity requirements. The connector **MUST** limit collected message data to metadata and activity signals needed for counting, attribution, timing, and traceability.

**Rationale**: The business requirement is activity analytics, not content archiving. Avoiding message content reduces privacy exposure and keeps the connector aligned with Insight's collaboration-metrics use case.

**Actors**: `cpt-insightspec-actor-zoom-operator`, `cpt-insightspec-actor-zoom-business-lead`

### 5.3 Connector Operations and Data Integrity

#### Support Incremental Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-incremental-collection`

The connector **MUST** support incremental collection so that ongoing runs process newly available meetings and message activity without requiring full historical reloads, using meeting-scoped or separate message flows as appropriate to source capabilities.

**Rationale**: Incremental collection is required for sustainable operation and for timely enrichment of new Zoom activity.

**Actors**: `cpt-insightspec-actor-zoom-operator`

#### Support Best-Effort Historical Backfill

- [ ] `p2` - **ID**: `cpt-insightspec-fr-zoom-historical-backfill`

The connector **SHOULD** support best-effort historical backfill during onboarding or recovery scenarios, limited by source retention, permissions, and endpoint availability at the time of collection.

**Rationale**: Older activity is valuable when available, but the business requirement prioritizes ongoing completeness over guaranteed deep history reconstruction.

**Actors**: `cpt-insightspec-actor-zoom-operator`, `cpt-insightspec-actor-zoom-analyst`

#### Record Collection Runs

- [ ] `p2` - **ID**: `cpt-insightspec-fr-zoom-collection-runs`

The connector **MUST** record collection run outcomes, including run timing, status, scope, and counts for discovered meetings, enriched meetings, participant records, user records, message activity, and errors.

**Rationale**: Operators need enough visibility to detect failed or incomplete runs before data quality issues spread downstream.

**Actors**: `cpt-insightspec-actor-zoom-operator`

#### Prevent Duplicate Activity Records

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-idempotence`

The connector **MUST** be idempotent across overlapping collection windows so that repeated or recovery runs do not create duplicate meeting, participant, user, or message activity records for the same source event.

**Rationale**: Incremental connectors commonly reprocess recent windows. Duplicate creation would corrupt meeting counts, attendance metrics, and message counts.

**Actors**: `cpt-insightspec-actor-zoom-operator`, `cpt-insightspec-actor-zoom-analyst`

### 5.4 Identity and Directory Support

#### Provide User Identity Support

- [ ] `p1` - **ID**: `cpt-insightspec-fr-zoom-user-identity-support`

The connector **MUST** collect Zoom user identity attributes required to associate meetings, participants, and message activity with source users and to support downstream identity resolution.

**Rationale**: Meeting and message analytics lose business value if activity cannot be attributed to real people or matched across systems.

**Actors**: `cpt-insightspec-actor-zoom-api`, `cpt-insightspec-actor-zoom-bronze-ingestion`

#### Limit User Collection to Support Needs

- [ ] `p2` - **ID**: `cpt-insightspec-fr-zoom-user-directory-scope`

The connector **MUST** limit Zoom user collection to attributes needed for activity attribution, identity resolution, and operational support, and **MUST NOT** position Zoom user data as a standalone workforce directory product.

**Rationale**: Zoom users are in scope only to support collaboration analytics, not to expand the connector into an HR or directory system.

**Actors**: `cpt-insightspec-actor-zoom-operator`, `cpt-insightspec-actor-zoom-bronze-ingestion`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Freshness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-zoom-freshness`

The connector **MUST** make newly collected meeting and message activity available to downstream consumers within 24 hours of source visibility for 95% of collection days under normal operating conditions.

**Threshold**: 95% of eligible days achieve end-to-end Bronze availability within 24 hours of source visibility over a rolling 90-day period.

**Rationale**: Collaboration analytics lose value when Zoom activity arrives too late for reporting and operational review.

#### Completeness of Enrichment

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-zoom-enrichment-completeness`

The connector **MUST** achieve complete meeting enrichment for at least 95% of newly discovered meetings, where completeness means the meeting has corresponding detail and participant data or an explicit source-side explanation for why a component is unavailable.

**Threshold**: 95% of newly discovered meetings meet the completeness rule over a rolling 90-day period.

**Rationale**: The primary business requirement depends on full per-meeting evidence, not just partial discovery.

#### Operational Resilience

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-zoom-operational-resilience`

The connector **MUST** tolerate retried runs, transient API failures, and overlapping recovery windows without producing inconsistent activity counts.

**Threshold**: Recovery or retry runs must preserve record uniqueness and produce no more than 0.5% unexplained variance in aggregate meeting or message counts for the reprocessed window.

**Rationale**: External API variability is expected, but it must not undermine trust in the collected metrics.

### 6.2 NFR Exclusions

- **Real-time streaming latency**: Not applicable because this connector is defined as a batch collector rather than an event-streaming integration.
- **Message content retention and discovery**: Not applicable because message content is explicitly out of scope for this release.
- **Webinar-specific completeness targets**: Not applicable because webinar collection is explicitly deferred to a later release.

## 7. Public Library Interfaces

### 7.1 Public API Surface

None.

### 7.2 External Integration Contracts

#### Zoom Source Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-zoom-source-activity`

**Direction**: required from client

**Protocol/Format**: Zoom APIs with account configuration, permissions, and retention behavior sufficient for meeting, participant, user, and message activity collection

**Compatibility**: The connector depends on continued availability of the required Zoom activity surfaces; source-side entitlement or contract changes may reduce completeness until the connector is updated

## 8. Use Cases

### UC-001 Collect Newly Discovered Meetings

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-zoom-collect-meetings`

**Actor**: `cpt-insightspec-actor-zoom-operator`

**Preconditions**:
- Zoom connector credentials and required scopes are configured
- A collection run starts for a window containing meetings not yet fully enriched

**Main Flow**:
1. The connector discovers newly visible Zoom meetings in the collection window
2. The connector records stable meeting identities and core meeting metadata
3. The connector triggers collection of meeting details for each newly discovered meeting
4. The connector collects participant records for each newly discovered meeting
5. The connector does not require message activity to be attached to the meeting unless the source exposes reliable meeting-level linkage
6. The connector records run results and exposes enriched activity for downstream processing

**Postconditions**:
- Each newly discovered meeting has corresponding detail and participant evidence
- Any meeting-linked message activity exposed by the source is preserved; otherwise message activity is collected through the appropriate separate flow

**Alternative Flows**:
- **Participant detail unavailable**: If Zoom does not provide participant detail for a discovered meeting, the connector records the limitation and marks the meeting as partially enriched rather than silently complete
- **API failure during enrichment**: If enrichment fails for a subset of meetings, the run records the failure and leaves those meetings eligible for retry in a follow-up cycle

### UC-002 Collect Zoom Message Activity

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-zoom-collect-messages`

**Actor**: `cpt-insightspec-actor-zoom-analyst`

**Preconditions**:
- Zoom message activity is available through the configured account and scopes
- The connector runs for a collection window with eligible message activity

**Main Flow**:
1. The connector determines whether Zoom exposes the required message metrics through a suitable aggregated or direct activity endpoint
2. If such an endpoint exists, the connector reads message activity from that source-supported path
3. If such an endpoint does not exist, the connector reads message activity through the appropriate separate message or chat collection flow
4. The connector attributes each message activity record to a source user
5. The connector persists message metadata needed for counting and timing analysis
6. The connector excludes message body content from persisted records
7. Downstream consumers aggregate message counts per user and time period

**Postconditions**:
- User-attributed Zoom message activity is available for analytics
- Message counts can be computed without storing message content

**Alternative Flows**:
- **No reliable meeting-level linkage**: If Zoom does not expose trustworthy meeting linkage for message activity, the connector preserves message activity without forcing a direct meeting association
- **Source limitations**: If a subset of message activity is not exposed by the source account, the connector records the limitation and proceeds with the supported message activity surfaces

## 9. Acceptance Criteria

- [ ] Insight can identify which Zoom meetings happened in the collection window and trace each collected meeting to a stable source meeting identifier
- [ ] Insight can determine who attended a collected Zoom meeting and how long each participant attended for the majority of eligible meetings
- [ ] Insight can compute per-user Zoom message counts without storing message content
- [ ] Newly discovered meetings trigger incremental enrichment for meeting detail and participants rather than remaining summary-only records
- [ ] Zoom message activity is collected through a suitable direct or aggregated activity source when available, or through separate message or chat collection flows when it is not
- [ ] Historical Zoom activity can be backfilled on a best-effort basis without changing the requirement for ongoing incremental collection

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Zoom account and application access | Required account configuration, authentication model, and permissions for meeting, participant, user, and message activity collection | p1 |
| Zoom activity endpoint availability | Source support for exposing discoverable meetings, participant attendance detail, and message activity | p1 |
| Identity Manager | Resolves Zoom user attributes to canonical `person_id` for cross-source analytics | p1 |
| Bronze ingestion infrastructure | Persists connector outputs and run logs for downstream processing | p1 |
| Scheduler and monitoring | Executes recurring runs and surfaces collection failures or completeness regressions | p2 |

## 11. Assumptions

- Zoom Meetings are the only synchronous Zoom activity in scope for this release; Zoom Phone is excluded
- Webinar collection will be addressed in a later release and does not need to be represented as a meeting in this PRD
- Message activity refers to all supported Zoom messages in scope, but not to message body content
- Zoom may expose message activity through aggregated or direct activity endpoints, separate chat flows, or both depending on source capabilities and tenant configuration
- Message activity may not always have a reliable direct linkage to a specific meeting and should not be forced into meeting-scoped enrichment when such linkage is absent
- Source account configuration provides enough participant detail to calculate attendance duration for most eligible meetings
- Historical backfill depth varies by tenant and should be treated as best-effort rather than guaranteed
- Normalized user identity attributes such as email are available often enough to support downstream identity resolution

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Zoom source limitations reduce participant visibility for some meetings | Attendance duration may be incomplete, weakening trust in collaboration metrics | Track completeness explicitly, record source-side limitations, and surface coverage gaps to operators |
| API fan-out for meeting enrichment is higher than expected | Large tenants may experience slower collection cycles or operational pressure during peak windows | Prioritize incremental collection, monitor enrichment completeness, and design scheduling around expected discovery volume |
| Message activity coverage differs across Zoom plans, endpoint availability, or account configurations | Per-user message counts may be incomplete or inconsistent across tenants, and meeting-level linkage may not always be available | Treat message coverage as a source dependency, support separate message collection flows, and expose linkage limitations in run reporting |
| Historical activity is not fully recoverable during onboarding | Early dashboards may start with partial history and create baseline gaps | Set onboarding expectations that backfill is best-effort and prioritize stable ongoing collection from day one |

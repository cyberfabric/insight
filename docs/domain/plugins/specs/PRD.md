# PRD — Plugin System

<!-- toc -->

- [Changelog](#changelog)
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
  - [5.1 Packaging and Distribution](#51-packaging-and-distribution)
  - [5.2 Installation and Dependency Resolution](#52-installation-and-dependency-resolution)
  - [5.3 Connector Capability](#53-connector-capability)
  - [5.4 Silver Capability](#54-silver-capability)
  - [5.5 Widget Capability](#55-widget-capability)
  - [5.6 Tenant Isolation and Versioning](#56-tenant-isolation-and-versioning)
  - [5.7 Configuration and Secrets](#57-configuration-and-secrets)
  - [5.8 Observability and Lifecycle](#58-observability-and-lifecycle)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
  - [UC-001 Tenant Admin Installs a Plugin from the Catalog](#uc-001-tenant-admin-installs-a-plugin-from-the-catalog)
  - [UC-002 Plugin Author Publishes a New Version](#uc-002-plugin-author-publishes-a-new-version)
  - [UC-003 Admin Upgrades a Plugin and Resolves Dependencies](#uc-003-admin-upgrades-a-plugin-and-resolves-dependencies)
  - [UC-004 Silver Plugin Consumes Bronze from a Connector Plugin](#uc-004-silver-plugin-consumes-bronze-from-a-connector-plugin)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Open Questions](#13-open-questions)

<!-- /toc -->

## Changelog

- **v1.0** (current): Initial PRD. Establishes a unified plugin model with composable capabilities (`connector`, `silver`, `widget`), tenant-scoped installation, explicit admin-driven dependency resolution, and bronze-as-sacred data policy. Defers manifest schema, native-protocol details, and authoring SDK to DESIGN/ADR and v2.

## 1. Overview

### 1.1 Purpose

The Plugin System is the extension mechanism of the Insight platform. It enables first-party teams, enterprise customers, and third-party authors to add new data sources, transformations, and visualizations to a running Insight instance without rebuilding the product and without coordinating a release cycle with the vendor.

Every plugin is a self-contained artifact published to an OCI registry. A tenant admin installs it through the product UI, the instance runtime resolves its dependencies, and its behavior is bounded by well-defined capability contracts: `connector` (writes bronze data from an external source), `silver` (normalizes bronze into cross-source semantic tables), and `widget` (renders part of the dashboard UI). A single plugin may declare any combination of these three capabilities.

### 1.2 Background / Problem Statement

Insight today ships with a fixed set of connectors, silver dbt models, and frontend widgets, all embedded in the product repository. Extending the system for a new source — GitLab, Jira, a bespoke internal system — requires a backend PR, frontend PR, dbt model updates, and a full release. A customer that wants to onboard a data source the vendor has not yet built cannot do so; an enterprise customer with internal tooling has no path to express its own metrics without forking the product.

Two additional pressures make the current model untenable. First, the ingestion substrate is transitioning from Airbyte to a native orchestration that gives the platform more control, and this transition should not require every connector to re-ship as a hand-written service. Second, the dashboarding surface is moving to a microfrontend model; the set of available widgets must expand at runtime, not at build time.

A plugin system decouples the vendor's release cadence from the customer's need to extend the product. It treats every new source, transform, and visualization as an installable unit with a declared contract, making the product extensible in the same way Airbyte makes source-system ingestion extensible, VS Code makes editor features extensible, or dbt packages make transformations extensible — but unified around a single artifact type so the contract across extension points is consistent.

**Target Users**:

- Tenant admins who need to onboard a data source or add a custom metric without vendor involvement
- Insight instance admins who set which plugins a tenant may install and manage the central catalog mirror
- Plugin authors (first-party, enterprise, third-party) who build and publish connectors, silver transformations, or widgets
- Downstream components (analytics-api, frontend, admin UI) that need a uniform way to discover and interact with installed extensions

**Key Problems Solved**:

- Customers can extend Insight with their own sources, transforms, and widgets without forking the product
- Vendor release cadence is decoupled from customer extension requests
- First-party and third-party extensions are subject to the same contract, so quality and support stories do not bifurcate
- The transition away from Airbyte does not require re-shipping every connector as product code
- Widgets extend the dashboarding surface at runtime rather than requiring a frontend rebuild

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- A tenant admin can install a first-party connector plugin end-to-end through the product UI in under 10 minutes (baseline: impossible today, requires vendor; target: self-service)
- A plugin author can ship a new version of an existing plugin to a customer without a product release (baseline: not supported; target: publish-to-registry + customer `install` is the full path)
- At least 3 distinct plugin authors (first-party, 1 enterprise customer, 1 third-party reference) have published working plugins against this contract before v1 is frozen (baseline: 0; target: 3)
- 100% of currently bundled ingestion connectors are expressible as plugins on this contract (baseline: all hard-coded in the repo; target: all refactored into the plugin model by end of rollout)
- Zero vendor releases required to add, upgrade, or remove a tenant's plugin set (baseline: required today; target: 0)

**Capabilities**:

- Publish a plugin to any OCI-compatible registry (Docker Hub, ghcr.io, a customer-owned registry)
- Discover available plugins through a central Insight catalog and through ad-hoc URL install
- Install, upgrade, and uninstall plugins per-tenant with explicit admin-driven dependency resolution
- Carry multiple versions of the same plugin within a single tenant when needed for migration
- Compose a plugin from one or more capabilities — `connector`, `silver`, `widget` — in a single artifact
- Coexist with the existing Airbyte-based ingestion substrate during the transition period
- Report per-plugin health, sync status, and dependency-graph state to instance admins

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Plugin | A versioned, self-contained extension packaged as an OCI artifact with a declarative manifest. A plugin declares one or more capabilities (`connector`, `silver`, `widget`) and its own dependencies on other plugins and on the platform. |
| Plugin ID | A globally unique reverse-DNS identifier for a plugin (for example, `com.cyberfabric.git-gitlab`). Namespace-per-author disambiguates plugins that would otherwise collide by short name. |
| Plugin version | A SemVer string attached to each published plugin build. Version comparison, range expressions, and breaking-change semantics follow SemVer 2.0. |
| Capability | One of three declared behaviors a plugin may contribute: `connector` (emits bronze data from a source system), `silver` (transforms bronze into unified silver tables), `widget` (renders a UI element). One plugin may declare any combination. |
| Manifest | The machine-readable declaration inside a plugin that describes its identity, capabilities, dependencies, input/output data contracts, config schema, and required secrets. Exact schema is defined in DESIGN. |
| Central catalog | The Insight-operated registry of curated plugins, serving metadata (identity, versions, compatibility, description) that the instance UI uses to populate the marketplace. A plugin can also be installed by direct URL without appearing in the catalog. |
| Plugin install | A record in an Insight instance's database that says "tenant T has plugin P at version X installed and enabled (or disabled)." The installed image + manifest is cached locally; its reconciliation into runtime resources is performed by the plugin runtime. |
| Plugin runtime | The subsystem inside the Insight instance that reconciles installed plugins into runtime state — fetches images, runs migrations, schedules connectors, applies silver transforms, registers widgets, reports health. |
| Connector capability | A plugin capability that fetches data from an external system and writes it to a per-install bronze scope in the data store. The execution protocol may be Airbyte, a future native Insight protocol, or any other protocol the author wants, as long as the plugin is a container that produces the declared bronze output. |
| Silver capability | A plugin capability that transforms bronze tables (possibly from multiple connectors) into silver tables with a unified cross-source schema. Execution engine is author's choice — dbt is the reference, but any container that reads declared inputs and writes declared outputs is allowed. |
| Widget capability | A plugin capability that provides a runtime-loaded frontend component (microfrontend) for the dashboard surface. Widgets declare their data contract as a table schema; the host application fetches data and passes it in via a stable interface. |
| Bronze data | Raw source data preserved verbatim from the external system. Treated as sacred — never deleted or transformed in place by the plugin system; retained so silver and gold layers can always be rebuilt by re-running downstream plugins. |
| Dependency resolution | The admin-API-driven process of determining, for a requested install or upgrade, what other plugin versions must coexist. Resolution is explicit and admin-approved; there is no auto-upgrade, auto-resolve, or "legacy compatibility" mode. |
| Plugin capability contract | The set of declared inputs (tables, config, secrets) and outputs (tables, widget interface) a capability exposes. Consumers (other plugins, the host app) rely on this contract; authors may add non-breaking fields within a major version. |

## 2. Actors

### 2.1 Human Actors

#### Plugin Author

**ID**: `cpt-plugin-actor-plugin-author`

**Role**: Builds, packages, and publishes plugins. May be a first-party Insight engineer shipping a bundled plugin, an enterprise customer's internal team building a plugin for their tenant, or a third-party publishing to the marketplace. Owns the plugin's manifest, image, tests, and backward compatibility commitments across versions.

**Needs**: A clear, stable contract for each capability; a reference plugin to copy; a published manifest schema; a path to test against a local Insight instance before publish; the ability to iterate without vendor gatekeeping for non-catalog plugins.

#### Instance Admin

**ID**: `cpt-plugin-actor-instance-admin`

**Role**: Operates an Insight instance. Controls which plugins the instance's tenants may install (through a mirror of the central catalog, an allowlist, or both), approves dependency resolutions, and intervenes when a plugin misbehaves. Owns the instance's overall plugin inventory and the external secret store configuration.

**Needs**: Visibility into every installed plugin across tenants with health and version; the ability to block, force-uninstall, or pin versions; a dependency graph view showing conflicts and reachability; an audit log of who installed or upgraded what.

#### Tenant Admin

**ID**: `cpt-plugin-actor-tenant-admin`

**Role**: Installs, configures, and removes plugins for their tenant. Picks from the instance-approved catalog or supplies a URL for an ad-hoc plugin. Configures each plugin install (credentials, workspace IDs, sync schedules) through the product UI.

**Needs**: A marketplace UI listing installable plugins with description and compatibility; a configuration form generated from the plugin's declared config schema; per-plugin status (last sync, error count); an uninstall path that does not orphan bronze data without warning.

### 2.2 System Actors

#### Plugin Runtime

**ID**: `cpt-plugin-actor-plugin-runtime`

**Role**: Reconciles the installed-plugin inventory into running state inside the instance. Pulls plugin images from the configured OCI registry, runs the plugin's migrations, schedules connector syncs, applies silver transforms, registers widgets with the frontend, and writes health telemetry back to the inventory.

#### Admin API

**ID**: `cpt-plugin-actor-admin-api`

**Role**: Exposes CRUD on plugin installs, invokes the dependency resolver, talks to the OCI registry to fetch manifests for resolution, and serves the marketplace UI and admin dashboards.

#### Central Catalog

**ID**: `cpt-plugin-actor-central-catalog`

**Role**: Insight-operated service that maintains curated plugin metadata (identity, versions, descriptions, compatibility ranges). Read-only from the instance's perspective. Instance admins mirror or filter it into their local marketplace; tenant admins do not query it directly.

#### OCI Registry

**ID**: `cpt-plugin-actor-oci-registry`

**Role**: Any OCI-compliant container registry (Docker Hub, ghcr.io, customer-owned). Stores plugin images and manifests. Plugin runtime pulls from here during install and upgrade. Air-gapped instances are expected to mirror images into a customer-owned registry.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Every plugin install must be able to reach the OCI registry it was installed from, OR the instance must mirror the image into a reachable registry during install. Air-gapped deployments require the latter.
- Plugin containers run in the same Kubernetes cluster as the Insight instance; cluster resource quotas apply per install.
- Plugin capabilities that write to the shared data store (`connector`, `silver`) require the platform to provide them with a scoped, per-install credential — they do not use the tenant's own DB credentials.
- Widget capability requires the host frontend to support the microfrontend loader that is being adopted for the product; until that lands, widget capability ships as `p2` (see FRs below).

## 4. Scope

### 4.1 In Scope

- Plugin artifact model — identity, versioning, manifest, OCI packaging, reverse-DNS naming, SemVer semantics
- The three capabilities — `connector`, `silver`, `widget` — and the contract each exposes to consumers
- Single-artifact multi-capability plugins (one plugin may mix `connector` + `silver` + `widget` contributions)
- Distribution — central Insight catalog + ad-hoc URL install; any OCI-compatible registry
- Installation lifecycle — install, upgrade, uninstall, disable, enable at tenant scope
- Dependency resolution — explicit, admin-driven, per-tenant, supporting multiple versions of the same plugin simultaneously
- Per-install configuration via a plugin-declared config schema; UI renders form from it
- Per-install secret storage via an external secret manager plus a manual-entry fallback
- Observability — per-plugin health, sync status, dependency-graph state surfaced to instance admin
- Transition-period coexistence with Airbyte — the connector capability can use the Airbyte protocol for connectors that already implement it and reuse the Airbyte destination to write bronze
- Bronze data preservation across plugin upgrades and version switches (bronze is sacred; silver/widget configs are re-derivable)

### 4.2 Out of Scope

- Plugin authoring SDK / CLI (`insight-plugin init|validate|test|package|publish`) — deferred to v2; v1 ships docs + reference plugins
- Automatic dependency resolution or auto-upgrade — every resolution is explicit and admin-approved
- "Legacy" compatibility mode — a plugin cannot be upgraded if its transitive dependencies cannot also be upgraded; the admin decides whether to proceed or stay on the old version
- Plugin sandboxing beyond standard Kubernetes container isolation (network policy, resource quota, serviceaccount scoping) — stronger sandboxing (gVisor, WASM) is a follow-up PRD
- Rollback of silver and widget data — these layers are re-derivable from bronze; plugin system does not snapshot them. Connectors MAY ship migrations for bronze-schema changes but are not required to
- Cross-tenant plugin sharing — each tenant install is independent; future federation is not in v1
- Exact manifest schema, exact database schema for the installed-plugin inventory, and the API/protocol shape for native-Insight (non-Airbyte) connectors — these are DESIGN-level and tracked in Open Questions
- Soft-delete / GDPR erasure tooling for plugin-produced data — inherited from platform-wide data lifecycle (separate PRD)
- Billing, metering, or marketplace payment flow — out of scope for v1 plugin system; any commercial model is a later program

## 5. Functional Requirements

### 5.1 Packaging and Distribution

#### Plugins Ship as OCI Artifacts

- [ ] `p1` - **ID**: `cpt-plugin-fr-oci-artifact`

Every plugin **MUST** be published as an OCI artifact (container image plus manifest metadata) to an OCI-compatible registry. The plugin system **MUST** accept plugins from Docker Hub, ghcr.io, and any registry that speaks the OCI distribution spec, including customer-owned private registries.

**Rationale**: Uniform packaging across first-party, enterprise, and third-party plugins; leverages an already-deployed ecosystem; supports air-gapped installations through registry mirroring.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-oci-registry`

#### Reverse-DNS Naming and SemVer Versioning

- [ ] `p1` - **ID**: `cpt-plugin-fr-naming-versioning`

Every plugin **MUST** be identified by a reverse-DNS identifier (`com.acme.git-gitlab`) that is globally unique across authors. Every published build **MUST** carry a SemVer 2.0 version. The plugin system **MUST** reject installs whose ID collides with an already-installed plugin from a different author.

**Rationale**: Reverse-DNS avoids short-name collisions between independent authors (two different `git` plugins). SemVer gives dependency resolution a principled ordering and a clear breaking-change signal.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-admin-api`

#### Central Catalog and URL Install Coexist

- [ ] `p1` - **ID**: `cpt-plugin-fr-catalog-and-url`

The plugin system **MUST** support two install sources: a curated central catalog (metadata served by the Insight-operated catalog service) and ad-hoc URL install (tenant admin supplies an OCI reference for a plugin that is not in the catalog). Instance admins **SHOULD** be able to restrict their tenants to catalog-only plugins via an instance-level policy.

**Rationale**: Central catalog enables discovery, curation, and compatibility testing for the common case. URL install enables customer-authored plugins that are never intended to be published publicly without requiring a catalog gatekeeping workflow.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-instance-admin`, `cpt-plugin-actor-central-catalog`

#### Declarative Manifest Per Plugin

- [ ] `p1` - **ID**: `cpt-plugin-fr-manifest`

Every plugin **MUST** ship a machine-readable manifest that declares at minimum: reverse-DNS identity, version, human-readable name, description, author/license, supported platform version range, the capabilities it contributes (`connector`, `silver`, `widget`, or any composition), for each capability its data contract (inputs, outputs), config schema, required secrets, and the plugin's dependencies on other plugins. The manifest schema itself is defined in DESIGN.

**Rationale**: The manifest is the contract that dependency resolution, UI form generation, catalog display, and health reporting all depend on. Without a declared manifest, the platform cannot install a plugin safely.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-admin-api`

### 5.2 Installation and Dependency Resolution

#### Tenant-Scoped Installs

- [ ] `p1` - **ID**: `cpt-plugin-fr-tenant-scoped-installs`

Every plugin install **MUST** be scoped to a single tenant. Two tenants in the same instance installing the same plugin **MUST** get independent installs — independent config, independent bronze scope, independent schedule. Instance admins **MAY** restrict the set of plugins available to tenants through allowlists or through catalog filtering.

**Rationale**: Tenants are the atomic billing / isolation boundary; shared installs would break tenant isolation and complicate uninstall.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-instance-admin`

#### Multiple Versions of the Same Plugin Coexist

- [ ] `p1` - **ID**: `cpt-plugin-fr-multi-version`

The plugin system **MUST** support installing two or more versions of the same plugin within a single tenant concurrently. This is the mechanism for migration across breaking changes — the old version keeps producing bronze while the new version is validated, then the old version is uninstalled.

**Rationale**: Without multi-version support, every breaking upgrade is a cutover that risks data loss or downtime. With it, migrations become incremental.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-plugin-runtime`

#### Explicit, Admin-Driven Dependency Resolution

- [ ] `p1` - **ID**: `cpt-plugin-fr-explicit-resolution`

When a tenant admin requests an install or upgrade, the admin API **MUST** compute the full set of plugins (and versions) that would need to be added or upgraded to satisfy the request and **MUST** present that set to the admin for approval before any change is applied. The admin **MUST** be able to reject the resolution. The plugin system **MUST NOT** automatically upgrade, downgrade, or uninstall plugins on the admin's behalf.

**Rationale**: Plugins may touch tenant-critical data. Surprise upgrades are unacceptable. Explicit resolution gives the admin a decision point and an audit trail; the default behavior of doing nothing unless approved is the safe default.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-admin-api`

#### No Legacy Compatibility Mode

- [ ] `p1` - **ID**: `cpt-plugin-fr-no-legacy-mode`

When a dependency cannot be satisfied (for example, plugin A at v2 requires plugin B at ≥3.0.0 but plugin B is pinned at 2.x for another plugin), the plugin system **MUST** refuse the install and surface the conflict to the admin. The plugin system **MUST NOT** attempt to run plugin A in a fallback mode against an older plugin B.

**Rationale**: Implicit "best-effort" compatibility layers compound indefinitely and create dependency-hell states that are impossible to reason about. Forcing an explicit choice keeps the dependency graph honest.

**Actors**: `cpt-plugin-actor-admin-api`, `cpt-plugin-actor-tenant-admin`

#### Inventory in Instance Database

- [ ] `p1` - **ID**: `cpt-plugin-fr-inventory-storage`

The plugin system **MUST** persist the per-tenant installed-plugin inventory (which plugin IDs, at which versions, enabled or disabled, when installed, by whom) in the instance database. The inventory **MUST** survive restarts, `helm upgrade` of the Insight umbrella, and reconciliation by the plugin runtime.

**Rationale**: The inventory is the source of truth about a tenant's extension surface. Storing it in the instance DB (not in Kubernetes CRDs) keeps it co-located with tenant data, enables transactional admin-API operations, and simplifies backup.

**Actors**: `cpt-plugin-actor-admin-api`, `cpt-plugin-actor-plugin-runtime`

#### Unused-Dependency Reporting

- [ ] `p2` - **ID**: `cpt-plugin-fr-unused-reporting`

The plugin system **SHOULD** identify plugin installs that were pulled in as transitive dependencies and are no longer referenced by any user-installed plugin, and **SHOULD** present them to the admin for optional uninstall. The system **MUST NOT** uninstall them automatically.

**Rationale**: Prevents dependency cruft from accumulating silently as plugins come and go. Keeps the surface area the admin has to reason about aligned with current reality.

**Actors**: `cpt-plugin-actor-instance-admin`

### 5.3 Connector Capability

#### Connector Emits Bronze to a Per-Install Scope

- [ ] `p1` - **ID**: `cpt-plugin-fr-connector-bronze-scope`

A plugin that declares the `connector` capability **MUST** emit its output into a per-install bronze scope in the data store, isolated from every other connector install (including other installs of the same plugin for the same tenant at different versions). Tables, schemas, and any other data-store namespace the connector uses **MUST** be derivable from the `(tenant_id, plugin_id, plugin_version, install_id)` tuple so scopes do not collide.

**Rationale**: Bronze data is the durable record of what the source system returned. Isolating scopes by install means uninstalls are safe (delete the scope), migrations between versions are safe (write to a new scope, validate, then switch), and multi-version coexistence works.

**Actors**: `cpt-plugin-actor-plugin-runtime`

#### Bronze Data Is Preserved Across Upgrades

- [ ] `p1` - **ID**: `cpt-plugin-fr-bronze-preserved`

The plugin system **MUST** preserve a connector install's bronze data across plugin upgrades unless the admin explicitly requests its deletion. Connector plugins **MAY** ship forward-only migrations for bronze schema evolution; silver and widget layers are always re-derivable and **MUST NOT** require any such migration.

**Rationale**: Bronze is the only layer not reconstructible from other layers. Losing it means losing history. Keeping it sacred is the single most important data-durability commitment of the plugin system.

**Actors**: `cpt-plugin-actor-plugin-runtime`

#### Connector Execution Protocol Is Author's Choice

- [ ] `p1` - **ID**: `cpt-plugin-fr-connector-protocol-flexibility`

A connector-capability plugin **MAY** be executed using any protocol its author chooses, as long as the running container produces bronze tables in its declared per-install scope. The plugin system **MUST** support the Airbyte source protocol (so that existing Airbyte connectors can be wrapped as Insight plugins with minimal rework) and **MUST** be extensible to other protocols — for example, Singer tap, or a future native Insight connector protocol — as they are adopted.

**Rationale**: Requires zero migration cost for the existing Airbyte connector fleet and avoids locking Insight into a single execution contract for the next decade. The platform's job is to give the connector a scope to write to and collect its output; how it produces that output is a plugin-internal concern.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Airbyte Connectors Reuse the Airbyte Destination for Bronze

- [ ] `p1` - **ID**: `cpt-plugin-fr-airbyte-destination-reuse`

For connector plugins that use the Airbyte source protocol, the plugin system **MUST** support using the existing Airbyte ClickHouse destination to write bronze, rather than reimplementing the destination inside the plugin runtime.

**Rationale**: The Airbyte destination is battle-tested for the types and quirks of ClickHouse ingestion. Reimplementing it for v1 is busywork and a regression risk.

**Actors**: `cpt-plugin-actor-plugin-runtime`

### 5.4 Silver Capability

#### Silver Transforms Bronze Into Unified Outputs

- [ ] `p1` - **ID**: `cpt-plugin-fr-silver-transform`

A plugin that declares the `silver` capability **MUST** transform one or more bronze inputs (from connector plugins it depends on) into silver output tables with declared schemas. The plugin **MUST** declare its input bronze tables (as `(plugin_id, plugin_version, table_name)` references) and its output silver tables (schema + columns) in its manifest.

**Rationale**: A silver plugin is in essence a function `bronze* → silver*`. Declaring both sides explicitly is what allows the dependency resolver to verify compatibility and the runtime to detect contract violations.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Transformation Engine Is Author's Choice

- [ ] `p1` - **ID**: `cpt-plugin-fr-silver-engine-flexibility`

Silver capability **MUST NOT** constrain the plugin to a specific transformation engine. dbt is the reference engine for the first-party silver plugins; authors **MAY** use Rust, Python, or any other language, provided the container reads the declared bronze inputs and writes the declared silver outputs.

**Rationale**: dbt's model is great for declarative SQL transforms but breaks down for algorithmic enrichment (identity resolution, ML scoring, custom aggregations). Forcing every silver plugin into dbt would either lock those cases out or contort them. Letting authors pick the engine keeps the capability broad.

**Actors**: `cpt-plugin-actor-plugin-author`

#### Silver Consumer Validates Its Inputs

- [ ] `p1` - **ID**: `cpt-plugin-fr-silver-consumer-validates`

A silver plugin **MAY** ship data-quality tests against its declared bronze inputs (dbt tests for dbt-based plugins; equivalent mechanism in the manifest for other engines). When such tests are present, the plugin runtime **MUST** execute them before running the transform and **MUST** report failures to the admin.

**Rationale**: Connectors evolve independently of silver plugins. The only robust defense against "connector sent us garbage today" is for the silver consumer to declare its expectations and check them before transforming. Shifts responsibility for compatibility to the party best positioned to enforce it.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

### 5.5 Widget Capability

#### Widget Ships as a Microfrontend Module

- [ ] `p1` - **ID**: `cpt-plugin-fr-widget-microfrontend`

A plugin that declares the `widget` capability **MUST** ship a microfrontend module that the Insight host frontend loads at runtime. The host frontend **MUST** fetch the module on demand — widgets are not bundled into the product build — and **MUST** render the module within the container-provided frame.

**Rationale**: Runtime-loaded widgets are the only way to extend the dashboard surface without a frontend rebuild. Microfrontend is the contract the rest of the frontend is already moving toward; reusing it here means widget-capability plugins do not need a separate runtime.

**Actors**: `cpt-plugin-actor-plugin-runtime`

#### Widget Receives Data from the Host App

- [ ] `p1` - **ID**: `cpt-plugin-fr-widget-data-contract`

A widget capability **MUST** declare its expected input data as a table schema (column names, types, nullability) and optional config (JSON schema). The host application **MUST** resolve the data based on the dashboard's widget-instance configuration, fetch it, and pass it to the widget through a stable interface. The widget **MUST NOT** query the data store directly.

**Rationale**: Centralizing data fetching in the host prevents widget plugins from leaking data between tenants, bypassing RLS, or holding long-lived DB credentials. The widget becomes a pure rendering function over (data, config), which is the minimum-privilege model.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Widget Config Is Merged Across Scopes

- [ ] `p2` - **ID**: `cpt-plugin-fr-widget-config-merge`

Widget configuration **MUST** be layered across scopes with narrower scopes overriding broader ones through deep merge: instance default (from the silver plugin that ships the widget wiring) → tenant → dashboard → widget-instance. The layering **MUST** be deterministic and **MUST** surface the effective merged config to admins for diagnostics.

**Rationale**: Real customers need per-tenant customization (branding, formatting) while keeping a sensible default. Deep merge lets admins change narrow slices of widget config without restating the whole thing at every layer.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-instance-admin`

### 5.6 Tenant Isolation and Versioning

#### Per-Tenant Data Isolation

- [ ] `p1` - **ID**: `cpt-plugin-fr-tenant-data-isolation`

All plugin-produced data **MUST** carry the `tenant_id` of the tenant it was produced for and **MUST** be queryable only within that tenant's scope. Cross-tenant reads from any plugin-produced table **MUST** be rejected by the data store's enforcement layer, not merely filtered by application code.

**Rationale**: Application-level filtering alone fails under bugs or malicious plugins. Enforcement at the data-store layer (row-level security policies or schema-per-tenant, as decided in DESIGN) is the only robust guarantee.

**Actors**: `cpt-plugin-actor-plugin-runtime`

#### Plugin Versions Follow SemVer

- [ ] `p1` - **ID**: `cpt-plugin-fr-semver-contracts`

Plugin authors **MUST** follow SemVer 2.0 — breaking changes to any declared capability contract (config schema, output tables, widget data contract) require a major-version bump. Additive changes **MAY** be minor versions; bug fixes **MAY** be patch versions. The plugin system's dependency resolver **MAY** use SemVer ranges in declared dependencies.

**Rationale**: Predictable version semantics are the foundation on which dependency resolution, upgrade approval, and author-to-consumer trust all sit. Without SemVer discipline, the graph is noise.

**Actors**: `cpt-plugin-actor-plugin-author`

### 5.7 Configuration and Secrets

#### Config Schema Drives the Install UI

- [ ] `p1` - **ID**: `cpt-plugin-fr-config-schema-ui`

Every plugin capability **MUST** declare its configuration requirements as a schema in its manifest. The admin UI **MUST** render a configuration form from that schema during install and configuration. The plugin system **MUST** validate submitted config against the schema before persisting it.

**Rationale**: Matches the tenant-UI install flow (Airbyte-like) without requiring custom UI per plugin. Validation at admin-API time catches misconfiguration early.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-admin-api`

#### Secrets Supplied Through External Store or Manual Input

- [ ] `p1` - **ID**: `cpt-plugin-fr-secret-provisioning`

Plugin capabilities that require secrets (API tokens, credentials) **MUST** declare them in the manifest. The plugin system **MUST** support providing them through (a) an external secret manager (configured at the instance level) and (b) a manual entry path in the admin UI for cases where no external store is wired up. Secrets **MUST NOT** be logged, leaked into manifests, or stored in the catalog.

**Rationale**: Enterprise customers expect secrets to flow through Vault, AWS Secrets Manager, or an equivalent. Small deployments need a fallback that does not require that infrastructure. Both paths are common, and the split keeps each simple.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-instance-admin`

### 5.8 Observability and Lifecycle

#### Plugins Report Operational Status

- [ ] `p1` - **ID**: `cpt-plugin-fr-status-reporting`

Every installed plugin **MUST** report its operational status to the plugin runtime: connector sync progress and errors, silver transform run outcomes and data-test failures, widget render failures. The plugin system **MUST** make this status available to the instance admin through the admin UI.

**Rationale**: Without telemetry flowing back, "the dashboard is wrong" degenerates into a manual hunt across four systems. Centralizing status inside the plugin inventory gives admins a single pane of glass.

**Actors**: `cpt-plugin-actor-plugin-runtime`, `cpt-plugin-actor-instance-admin`

#### Dependency Graph Surfaced to Admins

- [ ] `p2` - **ID**: `cpt-plugin-fr-dep-graph-ui`

Instance admins **SHOULD** be able to view the dependency graph across all installed plugins with per-node health state (healthy, degraded, broken, upgrade available). Tenant admins **SHOULD** see the subset of the graph relevant to their tenant.

**Rationale**: Plugin ecosystems grow dense fast. A visual graph is the only scalable way to find "what is broken and what does it block" when something fails.

**Actors**: `cpt-plugin-actor-instance-admin`, `cpt-plugin-actor-tenant-admin`

#### End-User Error Surface Is Minimal

- [ ] `p2` - **ID**: `cpt-plugin-fr-end-user-error`

Non-admin users **MUST NOT** be exposed to plugin-internal error detail. When plugin state prevents a dashboard or widget from rendering accurately, end users **MUST** see a generic "data temporarily unavailable" indicator; plugin-level diagnostics are surfaced only to admins.

**Rationale**: End users cannot act on plugin stack traces. Showing them is both a security concern (leaks plugin internals) and a UX regression.

**Actors**: `cpt-plugin-actor-plugin-runtime`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Install-to-Functional Time

- [ ] `p1` - **ID**: `cpt-plugin-nfr-install-latency`

From the moment a tenant admin approves an install through the admin UI to the moment the plugin is functional (first successful bronze write for connector; first successful transform for silver; widget available on the dashboard surface), the plugin system **MUST** complete the flow in under 10 minutes p95 for plugins up to 200 MB in image size on a standard instance.

**Threshold**: p95 ≤ 10 minutes, measured from install request to `status = ready`.

#### Per-Tenant Plugin Capacity

- [ ] `p2` - **ID**: `cpt-plugin-nfr-tenant-capacity`

An instance **MUST** support at least 50 plugin installs per tenant and at least 200 plugin installs total across all tenants without degradation of catalog or resolver performance beyond documented thresholds.

**Threshold**: 50 installs per tenant; 200 per instance; resolver completes in < 2 seconds p95 at this scale.

### 6.2 NFR Exclusions

- **Multi-region distribution** (OPS): Plugin system is co-located with the Insight instance it extends; multi-region replication is an instance-level concern, not a plugin-level one.
- **Offline support** (UX): The admin UI that drives plugin install is an online tool. Air-gapped installation uses a mirrored OCI registry; offline authoring is out of scope.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Plugin Catalog API

- [ ] `p1` - **ID**: `cpt-plugin-interface-catalog-api`

**Type**: REST API (read-only for tenant admins; read/write for instance admins)

**Stability**: stable

**Description**: Lists plugins available for install (merged view of central catalog + instance-local overrides + URL-installable check). Exposes plugin identity, available versions, description, declared capabilities, and compatibility range. The exact endpoint shape, pagination, and response payload are specified in DESIGN.

**Breaking Change Policy**: Additive fields non-breaking. Removing or renaming fields is a major version bump with a two-minor-release deprecation window.

#### Plugin Install API

- [ ] `p1` - **ID**: `cpt-plugin-interface-install-api`

**Type**: REST API (tenant admin + instance admin)

**Stability**: stable

**Description**: CRUD on installed plugins: request install, approve a resolved plan, upgrade, downgrade, enable, disable, uninstall. Every mutation produces an auditable event; every install change is presented as a resolved plan first and only applied on explicit approval.

**Breaking Change Policy**: Same as catalog API.

#### Plugin Runtime Interface

- [ ] `p1` - **ID**: `cpt-plugin-interface-runtime`

**Type**: Internal interface between the admin API and the plugin runtime

**Stability**: unstable (v1); target stable by v2

**Description**: Describes how a requested install/upgrade/uninstall is reconciled into runtime state — fetching the image, running the capability entrypoints, registering widgets with the frontend, surfacing status. Shape is defined in DESIGN.

### 7.2 External Integration Contracts

#### OCI Registry Contract

- [ ] `p1` - **ID**: `cpt-plugin-contract-oci`

**Direction**: required from external registry

**Protocol/Format**: OCI distribution spec v1.

**Compatibility**: Any registry that speaks OCI v1 works. Private registries require a pull credential configured at the instance level.

#### Plugin Capability Contracts

- [ ] `p1` - **ID**: `cpt-plugin-contract-capabilities`

**Direction**: provided by platform, required of plugins

**Protocol/Format**: For each of `connector`, `silver`, `widget`, the set of declared inputs/outputs in the manifest is the contract. A plugin that does not honor its declared contract (emits wrong tables, demands unmet config, etc.) is considered broken and **MUST** be surfaced as such by the plugin runtime.

**Compatibility**: Additive capability-contract evolution is allowed within a major version. Breaking changes require a major bump and explicit admin-approved migration.

## 8. Use Cases

### UC-001 Tenant Admin Installs a Plugin from the Catalog

**ID**: `cpt-plugin-usecase-install-from-catalog`

**Actor**: `cpt-plugin-actor-tenant-admin`

**Preconditions**: The tenant has at least one admin; the instance has the central catalog configured; the target plugin is in the catalog and not blocked at the instance level.

**Main Flow**:

1. Admin opens the plugin marketplace in the product UI and selects a plugin
2. UI displays the plugin's description, declared capabilities, compatibility range, and required config
3. Admin clicks Install; the admin API invokes the resolver
4. Resolver returns a resolved plan (this plugin + any dependencies with versions)
5. UI shows the plan and asks the admin to approve
6. Admin approves; plugin runtime pulls the image(s), runs any bronze migrations, configures the install, and activates it
7. Admin is presented with a configuration form generated from the plugin's config schema
8. Admin supplies configuration and secrets; the plugin begins operating within its declared capability

**Postconditions**: The plugin is installed, enabled, configured, and reporting status to the inventory. No prior plugins were modified.

**Alternative Flows**:

- **Resolver finds a conflict**: The resolver surfaces the specific conflict (plugin X requires version Y of plugin Z, but plugin Z is pinned at another version); admin rejects the plan or asks the owner of the conflicting plugin to upgrade. No state changes.
- **Image pull fails**: The install is marked failed; no state is partially applied. Admin retries or escalates to instance admin.

### UC-002 Plugin Author Publishes a New Version

**ID**: `cpt-plugin-usecase-publish-new-version`

**Actor**: `cpt-plugin-actor-plugin-author`

**Preconditions**: The author has write access to an OCI registry and an existing plugin at version N.

**Main Flow**:

1. Author bumps the version in the plugin manifest per SemVer rules
2. Author builds the image, runs local validation against the documented contract, and pushes it to the registry
3. If the plugin is in the central catalog, the author (or their team) updates the catalog entry with the new version
4. Existing tenant admins see the new version appear in the UI as "upgrade available"

**Postconditions**: The new version is discoverable. Existing installs at the prior version continue to operate unchanged until their admins explicitly upgrade.

**Alternative Flows**:

- **Breaking change**: Author bumps the major version. Tenant admins see the upgrade as "breaking — major bump" in the UI and must explicitly opt in; the resolver flags dependent plugins that would also need upgrading.

### UC-003 Admin Upgrades a Plugin and Resolves Dependencies

**ID**: `cpt-plugin-usecase-upgrade-with-deps`

**Actor**: `cpt-plugin-actor-tenant-admin`

**Preconditions**: A plugin install exists; a newer version is available that requires a new version of another plugin.

**Main Flow**:

1. Admin selects Upgrade on the plugin's tile
2. Resolver computes the transitive upgrade plan (this plugin + dependencies)
3. UI shows the plan; admin sees exactly which other plugins will upgrade and to what versions
4. Admin approves; plugin runtime performs each upgrade in dependency order, preserving bronze data and re-deriving silver and widget state
5. Inventory is updated; admin sees all participating plugins at their new versions and status reports green

**Postconditions**: Upgraded plugins are running; bronze data is preserved across the transition.

**Alternative Flows**:

- **Admin rejects plan**: No changes applied. Plugin remains at the prior version. The "upgrade available" indicator persists.
- **One plugin in the chain fails mid-upgrade**: The runtime pauses the chain, reports the failure, and requires admin intervention (retry or rollback).

### UC-004 Silver Plugin Consumes Bronze from a Connector Plugin

**ID**: `cpt-plugin-usecase-silver-consumes-bronze`

**Actor**: `cpt-plugin-actor-plugin-runtime`

**Preconditions**: A connector plugin and a silver plugin are both installed; the silver plugin declares a dependency on the connector plugin's output bronze tables at a specific major version.

**Main Flow**:

1. Connector plugin completes a sync and writes updated bronze
2. Plugin runtime triggers the silver plugin, passing the declared bronze inputs
3. Silver plugin runs its data-quality tests against the bronze inputs (per `cpt-plugin-fr-silver-consumer-validates`)
4. Tests pass; silver plugin runs its transform and writes silver outputs
5. Runtime records success; downstream consumers (widgets, analytics-api) observe refreshed silver data

**Postconditions**: Silver data is current; bronze is unchanged; status is green.

**Alternative Flows**:

- **Data-quality test fails**: Transform is not run; the failure is surfaced to the admin (instance and tenant) with a pointer to the failing test and the offending input. No silver state is overwritten with bad data.
- **Bronze schema changed unexpectedly**: Silver plugin's declared input contract no longer matches; runtime refuses the run and surfaces the contract mismatch to the admin, who must either upgrade the silver plugin or downgrade the connector.

## 9. Acceptance Criteria

- [ ] A plugin with `connector` capability can be published to ghcr.io and installed in an Insight instance through the marketplace UI, end to end, with no code changes to the Insight product
- [ ] A plugin with `silver` capability that depends on a connector plugin cannot be installed if its declared dependency is unmet; the admin sees the unmet dependency in the resolver output
- [ ] A plugin that combines `connector` + `silver` + `widget` in a single manifest installs as one artifact and each capability becomes operational independently
- [ ] Two versions of the same plugin can coexist in one tenant; uninstalling the older version does not affect the newer version's bronze data
- [ ] Uninstalling a plugin preserves its bronze data unless the admin explicitly opts in to deletion
- [ ] Upgrading a plugin to a new major version requires explicit admin approval of the full transitive upgrade plan
- [ ] A connector plugin using the Airbyte source protocol can be installed without the plugin author reimplementing destination logic
- [ ] A widget plugin loads in the host frontend at runtime without a product rebuild
- [ ] When a silver plugin's data-quality tests fail, the transform does not run and an admin-visible failure is recorded
- [ ] An instance admin can view the dependency graph of all installed plugins across all tenants, with per-node health state
- [ ] Attempting to install a plugin whose manifest is invalid (missing required fields, malformed schema) fails at the admin-API layer with a clear error, before any runtime action
- [ ] All plugin-produced tables carry `tenant_id` and cross-tenant reads are rejected by the data-store enforcement layer

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| OCI-compatible registry | Hosts plugin artifacts. Must be reachable from the instance or mirrored for air-gapped installs | p1 |
| Instance database | Stores the installed-plugin inventory, config, and audit log | p1 |
| Plugin runtime subsystem | Reconciles inventory into runtime state (Kubernetes workloads, frontend widget registration) | p1 |
| Host frontend microfrontend loader | Required for widget capability; `widget` FRs ship when this is available | p2 |
| Ingestion orchestration (Argo Workflows today) | Schedules connector syncs and silver transforms; called by the plugin runtime | p1 |
| External secret manager (optional) | Provides plugin credentials when configured; manual-entry fallback otherwise | p2 |
| Central catalog service | Curates and serves public plugin metadata | p2 (URL install works without it) |

## 11. Assumptions

- Insight instances run on Kubernetes; plugin containers are scheduled as Kubernetes workloads by the plugin runtime.
- Tenants are the atomic isolation boundary; a plugin install never spans tenants in v1.
- The product's existing microfrontend technology becomes available on the timeline expected for widget capability to ship at `p1`.
- The platform's existing Argo Workflows deployment is the orchestrator used to execute connector syncs and silver transforms; plugins do not bring their own scheduler.
- SemVer discipline is realistic to enforce on first-party and enterprise plugins; third-party plugins in the catalog may be checked by Insight before acceptance.
- Bronze data volumes remain within single-cluster capacity for v1; cross-cluster plugin coordination is not required.

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Plugin authors misuse SemVer, shipping breaking changes as minor versions | Silent downstream breakage across tenants | Central-catalog entries run compatibility checks before listing; URL-install carries an explicit "untrusted source" warning in the admin UI; consumer plugins ship data-quality tests as the last line of defense |
| Dependency graph explodes into conflict states admins cannot untangle | Plugins become effectively impossible to upgrade | No-legacy-mode plus explicit resolution forces the conflict to the surface; dependency-graph UI gives admins visibility; unused-dependency reporting keeps the graph from accumulating cruft |
| Connector plugins write garbage bronze — typo, API change, malicious plugin — and silver consumers can't tell | Silver / gold layers quietly corrupt | Silver consumers ship their own data-quality tests against declared input contracts; plugin system runs them pre-transform and halts on failure |
| OCI registry is the single point of failure for install and upgrade | Plugin system unavailable when registry is down | Air-gapped path supports mirroring; instance admins can cache plugin images locally; install is idempotent so retry is safe |
| Plugin runtime crash leaves an install in a half-applied state | Manual recovery required | Every install/upgrade plan is persisted before application; runtime is reconciliation-based, so restart resumes from persisted state |
| Widget plugin escapes its sandbox and accesses tenant data it should not | Tenant data leakage | Widget does not query the data store directly; host app resolves the query and passes only the narrowed result; Kubernetes network policies restrict plugin pods to their declared egress |
| Third-party plugin becomes unmaintained and no one upgrades it past a breaking platform version | Tenants stuck, cannot upgrade platform | Central catalog marks maintenance status; instance admins can block unmaintained plugins; customers relying on third-party plugins are recommended to fork-on-need |
| Cost / resource explosion from tenants installing many heavy connectors | Cluster resource exhaustion | Plugin installs inherit per-tenant resource quotas enforced at the Kubernetes level; instance admins can cap plugins per tenant |
| Bronze data retention and delete flows conflict with GDPR / compliance requirements | Regulatory exposure | Bronze-is-sacred is a plugin-system guarantee; GDPR erasure is handled by a platform-level data-lifecycle tool that can drop a tenant's bronze scope on lawful request — not part of this PRD |

## 13. Open Questions

| Question | Owner | Target Resolution |
|----------|-------|-------------------|
| Plugin manifest schema — exact YAML shape, required vs optional fields, how capabilities are expressed, extension points for future capability kinds | Backend tech lead + Plugin Author lead | DESIGN / first ADR |
| Native Insight Connector Protocol — if and when we define a protocol beyond Airbyte wrapping; stdin/stdout JSONL vs gRPC vs OpenAPI endpoints; is the protocol necessary in v1 or is "container writes to its declared scope" enough | Ingestion tech lead | DESIGN / second ADR, post-v1 if possible |
| Per-tenant isolation mechanism — single table with `tenant_id` column and RLS policies, vs schema-per-install — which better suits on-prem distribution; current platform uses the former at the table level | Data tech lead | DESIGN |
| Installed-inventory data model — exact tables, status state machine, audit log shape, relationship between plugin install and its per-install bronze scope | Backend tech lead | DESIGN |
| Integration testing strategy — how does a plugin author test their plugin against a real customer data shape when the customer's source system is behind a firewall that Insight cannot reach; options include recorded/anonymized request traces shipped to the author, an opt-in customer-side trace-collection service operated by the Insight team, mock servers per connector type, or a combination | Plugin Author lead + Customer Success | DESIGN + customer-engagement policy; track separately from the data-model DESIGN |
| Plugin-authoring SDK / CLI — `insight-plugin init|validate|test|package|publish` — is it v1 ("can't ship without this") or v2 ("docs + reference plugins first, CLI when patterns stabilize"); the intent is the latter, but the threshold at which the CLI becomes a necessity should be articulated | Plugin Author lead | v2 planning; revisit after first three external plugins |
| Widget data-contract expressiveness — is "table schema with columns + config JSON schema" sufficient for the interesting widget cases, or does it need streaming, multi-query, or cross-entity access; depends on dashboard-configurator direction | Frontend tech lead | DESIGN, after first 3 widget plugins |
| Catalog governance — who approves a third-party plugin's inclusion in the central catalog, what compatibility tests run, how unmaintained plugins are retired; policy, not technical | Insight Product Team | Policy doc, before third-party publish path opens |
| Cross-tenant plugin sharing — an instance admin shipping a plugin-install across all tenants in one step (for a customer with many tenants in one instance); whether this is a v1 convenience or belongs in v2 | Insight Product Team | v2 planning |
| Plugin health → end-user surface — what exactly does "data temporarily unavailable" look like; is it per-widget or per-dashboard; does it communicate "connector X failed" vs "silver transform failed" to the user or only to the admin | Product design + Frontend | Coordinated design pass before first external plugin ships |
| Transition off Airbyte — at what point does the connector capability stop needing Airbyte source protocol support (when all connector plugins are native) and is removing that support a major-version bump of the plugin system | Ingestion tech lead | Roadmap item after native protocol stabilizes |

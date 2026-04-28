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
  - [5.2 Snapshot-Based Versioning and Installation](#52-snapshot-based-versioning-and-installation)
  - [5.3 Connector Capability](#53-connector-capability)
  - [5.4 Silver Capability](#54-silver-capability)
  - [5.5 Widget Capability](#55-widget-capability)
  - [5.6 Tenant Isolation and Versioning](#56-tenant-isolation-and-versioning)
  - [5.7 Configuration and Secrets](#57-configuration-and-secrets)
  - [5.8 Observability and Lifecycle](#58-observability-and-lifecycle)
  - [5.9 Security and Trust Model](#59-security-and-trust-model)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
  - [UC-001 Tenant Admin Installs a Plugin from the Catalog](#uc-001-tenant-admin-installs-a-plugin-from-the-catalog)
  - [UC-002 Plugin Author Publishes a New Version](#uc-002-plugin-author-publishes-a-new-version)
  - [UC-003 Tenant Admin Promotes a New Snapshot](#uc-003-tenant-admin-promotes-a-new-snapshot)
  - [UC-004 Silver Plugin Consumes Bronze from a Connector Plugin](#uc-004-silver-plugin-consumes-bronze-from-a-connector-plugin)
  - [UC-005 Tenant Admin Authors a Custom Snapshot](#uc-005-tenant-admin-authors-a-custom-snapshot)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Open Questions](#13-open-questions)

<!-- /toc -->

## Changelog

- **v1.3** (current): Major restructure addressing the second wave of PR #230 review comments (cyberantonz, ~24 comments). Six themes:
  1. **Snapshot model replaces per-plugin runtime resolution.** A *snapshot* is an immutable, named, tenant-curated set of `{plugin_id: version, ...}`. Conflicts are resolved at snapshot authoring time, never at install. Two snapshots can coexist arbitrarily long as fully independent data planes (own DB scopes, own per-install credentials, own pods). Upgrade = create a new snapshot alongside the old, run both in parallel, the tenant admin promotes when satisfied. Closes the version-hell concern raised on the resolver text (no runtime conflict states reach the tenant) and the multi-version routing concern (each snapshot is its own data plane). Vendor-published snapshots are an *optional convenience*, not a governance gate — tenant authoring is the default.
  2. **Per-install ClickHouse user with scoped GRANTs.** Every plugin install gets a generated CH user; GRANTs are scoped to its own bronze / silver scope (and, for silver, to the discovered upstream bronze scopes). Default user is forbidden for plugins. Closes data-plane access concerns (plugin doing `SELECT * FROM another_tenant_db`, plugin writing with a forged `tenant_id`, plugin enumerating `system.tables` to find anything not its own).
  3. **Plugin-shipped migrations via cross-snapshot SELECT GRANTs and SQL views.** Plugin authors ship migration scripts; the runtime grants the new snapshot's CH user `SELECT` on the prior snapshot's bronze for the duration of the trial period. Migrations may be expressed as `CREATE VIEW`, `MATERIALIZED VIEW`, or full `INSERT FROM SELECT`. Storage cost during a trial is `~1× + delta`, not `2×`. Closes the storage explosion concern.
  4. **Trial period is a soft reminder, not a hard timer.** Adaptation is open-ended. The trial timer surfaces a reminder ("you switched N days ago, retire the old snapshot?") but does not auto-revert. Removes the contradiction CodeRabbit flagged between UC-003 and the FR.
  5. **New Section 5.9 — Security.** Three FRs: image-signing-required (cosign + digest pinning), trust-tiers (vendor-signed / instance-signed / unsigned, with capability matrix), baseline-isolation (per-install CH user, NetworkPolicy egress allowlist, ResourceQuota, default ServiceAccount with no K8s API access — applies to ALL plugins regardless of trust tier). Closes supply-chain concerns (image swap, naming collision, mutable tags, abandoned-plugin tampering) and runtime-sandbox concerns (scanners/miners/VPN inside cluster, widget JWT theft).
  6. **Priority rebalance.** Previously every release-relevant FR was `p1`; cyberantonz noted "when everything is p1, nothing is." Re-ranked across all sections — `p1` is now reserved for items without which v1 cannot ship safely (~12 FRs); functional features and UX polish are `p2`; future improvements are `p3`.
- **v1.2**: Four changes addressing PR #230 review comments.
  1. **Rollback is replaced by shadow-deploy.** The plugin system never mutates a live install in place. An upgrade installs the new version alongside the old one, both run for a tenant-configurable trial period against the same inputs, the admin inspects a comparison view, and either PROMOTES the shadow stack (old one is uninstalled; bronze retained) or REJECTS it (shadow stack is uninstalled; tenant returns to the unchanged live stack). Expired trials default to REJECT. There is no distinct rollback operation. New FR `cpt-plugin-fr-snapshot-shadow-deploy`; UC-003 rewritten to this model (addresses `cyberantonz` review comment).
  2. **Each plugin ships its own isolated transform project.** Plugins MUST NOT use dbt `ref()` across plugin boundaries; downstream plugins discover upstream outputs only through the schema-based input contract, and the runtime injects `sources.yml` at run time. No global dbt DAG spans plugins. New FR `cpt-plugin-fr-isolated-transform-project`. Aligns transformation mechanics with the independent-authorship goal already stated for packaging and versioning.
  3. **Dependency-graph UI elevated to p1/MUST.** Given non-auto-healing behavior (no legacy mode, no silent rollback) and the shadow-deploy workflow, tenant and instance admins cannot operate the plugin system without a graph view of live + shadow stacks and per-node health. `cpt-plugin-fr-dep-graph-ui` now MUST and p1, matching the acceptance criterion that already assumed it.
  4. **UC-004 preconditions fixed.** v1.1 refactored silver to schema-based input contracts but missed the UC-004 preconditions paragraph; it still said "silver declares a dependency on the connector plugin." Rewritten to match `cpt-plugin-fr-silver-input-contract`.
- **v1.1**: Clarified four points after product-team review.
  1. Connectors are responsible not only for fetching data but also for normalizing it into their declared output schema — bronze is what the connector declares, not the vendor's raw payload.
  2. Silver plugins are decoupled from their suppliers by design: a silver plugin declares the input schema it expects plus discovery rules (tags, patterns, or install-time parameters) for locating source tables, and does NOT declare plugin-level dependencies on connectors. Contract matching is schema-based; a new connector that produces the expected shape feeds existing silver without either side knowing about the other. `UNION ALL` across discovered sources is the recommended pattern but not a requirement.
  3. The platform does not validate widget input data on the wire — the host app is a data proxy. Widgets that want input validation ship their own data tests (dbt or equivalent); the plugin runtime executes them before render.
  4. Tenant upgrade sovereignty is explicit: the instance admin can set policy (catalog allowlists, block lists, force-uninstall a broken plugin) but **cannot** install or upgrade plugins for a tenant. Upgrade decisions stay with the tenant admin so that a bad upgrade is caught by the party responsible for the data.
- **v1.0**: Initial PRD. Established a unified plugin model with composable capabilities (`connector`, `silver`, `widget`), tenant-scoped installation, explicit admin-driven dependency resolution, and bronze-as-sacred data policy. Deferred manifest schema, native-protocol details, and authoring SDK to DESIGN/ADR and v2.

## 1. Overview

### 1.1 Purpose

The Plugin System is the extension mechanism of the Insight platform. It enables first-party teams, enterprise customers, and third-party authors to add new data sources, transformations, and visualizations to a running Insight instance without rebuilding the product and without coordinating a release cycle with the vendor.

Every plugin is a self-contained artifact published to an OCI registry. A tenant admin installs it through the product UI, the instance runtime resolves its dependencies, and its behavior is bounded by well-defined capability contracts: `connector` (fetches from a source system and writes out a declared, normalized schema — its bronze), `silver` (discovers bronze tables matching a declared input contract and produces cross-source silver tables), and `widget` (renders part of the dashboard UI). A single plugin may declare any combination of these three capabilities.

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

- Publish a plugin to any OCI-compatible registry (Docker Hub, ghcr.io, a customer-owned registry), pinned by digest and signed (cosign / Sigstore)
- Compose a plugin from one or more capabilities — `connector`, `silver`, `widget` — in a single artifact
- Author and operate **tenant-owned snapshots** — declarations of which plugins at which versions run for the tenant — and upgrade by promoting a shadow snapshot validated alongside the live one on real data
- Carry the full plugin set, plugin-shipped migrations, and per-install ClickHouse credentials independently per snapshot, so two snapshots run as fully isolated data planes
- Discover available plugins through any OCI registry; central catalog is optional convenience
- Coexist with the existing Airbyte-based ingestion substrate during the transition period
- Modulate plugin capabilities by trust tier (vendor-signed / instance-signed / unsigned) above a fixed isolation baseline that applies to every plugin
- Report per-plugin health, per-snapshot status, and dependency-graph state to instance and tenant admins

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
| Connector capability | A plugin capability that fetches data from an external system, normalizes it into its declared output schema, and writes it to the connector's per-install bronze scope. Normalization is the connector's responsibility — a downstream silver plugin expects the connector to have already shaped the data, not raw vendor payloads. The execution protocol may be Airbyte, a future native Insight protocol, or any other protocol the author wants, as long as the running container produces the declared bronze output. |
| Silver capability | A plugin capability that discovers bronze tables matching a declared input contract (schema + discovery rules — tags, name patterns, or install-time parameters) and produces silver tables with a unified cross-source schema. Silver plugins are decoupled from specific connectors by design: they match on the input contract, not on a connector's plugin identity. The recommended default is a `UNION ALL` across discovered sources followed by incremental consolidation, but plugins MAY skip that step and emit derived tables directly. Execution engine is author's choice — dbt is the reference. |
| Widget capability | A plugin capability that provides a runtime-loaded frontend component (microfrontend) for the dashboard surface. A widget declares the data shape it expects; the host application fetches data by reference and passes it to the widget through a stable interface **without validating its shape or content**. Widgets that want input validation ship their own data tests (dbt or equivalent) and the plugin runtime executes them before rendering. |
| Bronze data | The data a connector plugin writes to its per-install scope in the connector's declared output schema (not the vendor's raw payload — the connector is responsible for normalizing into its declared shape). Treated as sacred — never deleted or transformed in place by the plugin system; retained so silver and gold layers can always be rebuilt by re-running downstream plugins. |
| Snapshot | A tenant-owned, immutable, named declaration of a plugin set: `{plugin_id: version, ...}`. The unit of versioning at tenant scope. A tenant runs one *live* snapshot; *shadow* snapshots may coexist for adaptation. Each snapshot has its own DB scopes (`bronze_<snapshot>_<install>`, `silver_<snapshot>_<install>`), per-install credentials, and pods — two snapshots are fully independent data planes. Snapshots may inherit from a vendor- or instance-published reference snapshot; the unit of authorship is the tenant. |
| Trial period | The window during which a freshly-installed shadow snapshot runs alongside the live snapshot. Open-ended; the trial timer surfaces a reminder for the tenant admin to either promote or retire the shadow, but does not auto-promote or auto-revert. |
| Trust tier | The provenance level of a plugin: *vendor-signed* (Insight's signature), *instance-signed* (a signature from a key the instance admin registered as trusted), or *unsigned*. Trust tier modulates capabilities ON TOP of baseline isolation, which applies regardless of tier. |
| Dependency resolution | The process of determining, for a requested install or upgrade, what other plugin versions must coexist. In v1.3 this happens at *snapshot authoring time* (the snapshot's curator picks a self-consistent set), not at runtime install. The runtime simply applies the snapshot as-given. |
| Plugin capability contract | The set of declared inputs (tables, config, secrets) and outputs (tables, widget interface) a capability exposes. Consumers (other plugins, the host app) rely on this contract; authors may add non-breaking fields within a major version. |

## 2. Actors

### 2.1 Human Actors

#### Plugin Author

**ID**: `cpt-plugin-actor-plugin-author`

**Role**: Builds, packages, and publishes plugins. May be a first-party Insight engineer shipping a bundled plugin, an enterprise customer's internal team building a plugin for their tenant, or a third-party publishing to the marketplace. Owns the plugin's manifest, image, tests, and backward compatibility commitments across versions.

**Needs**: A clear, stable contract for each capability; a reference plugin to copy; a published manifest schema; a path to test against a local Insight instance before publish; the ability to iterate without vendor gatekeeping for non-catalog plugins.

#### Instance Admin

**ID**: `cpt-plugin-actor-instance-admin`

**Role**: Operates an Insight instance. Holds an **oversight** role over the plugin surface — not a gatekeeping one. Instance admins **can** (when they choose to) set catalog allowlists/blocklists, force-uninstall a broken or unsafe plugin, and restrict which plugins their tenants may install; this is optional, not required, and the default instance policy allows tenants to self-serve. Instance admins **cannot** install, upgrade, or reconfigure plugins on a tenant's behalf — every change that touches tenant data is initiated by the tenant admin so that the party responsible for the data is the one who approves each change. Owns the instance's overall plugin inventory visibility and the external secret store configuration.

**Needs**: Visibility into every installed plugin across tenants with health and version; the ability to block or force-uninstall a specific plugin when safety requires; a dependency graph view showing conflicts and reachability; an audit log of who installed or upgraded what.

#### Tenant Admin

**ID**: `cpt-plugin-actor-tenant-admin`

**Role**: Curates and operates the tenant's plugin surface. Authors *snapshots* — tenant-owned declarations of which plugins at which versions run for the tenant — and decides when to upgrade by initiating a shadow-deploy of a new snapshot. Configures each plugin install (credentials, workspace IDs, sync schedules) through the product UI. Optionally inherits from a vendor-published or instance-published reference snapshot to bootstrap.

**Needs**: A marketplace UI listing installable plugins with description, trust tier, and compatibility; a snapshot editor (or "save as snapshot" from a current state); a side-by-side comparison view between the live and shadow snapshot during adaptation; a configuration form generated from each plugin's declared config schema; per-plugin status (last sync, error count); an uninstall path that does not orphan bronze data without warning.

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

- Plugin artifact model — identity, versioning, manifest, OCI packaging by digest, reverse-DNS naming, SemVer semantics, image signing (cosign / Sigstore)
- The three capabilities — `connector`, `silver`, `widget` — and the contract each exposes to consumers
- Single-artifact multi-capability plugins (one plugin may mix `connector` + `silver` + `widget` contributions)
- Distribution — any OCI-compatible registry; central Insight catalog as optional convenience
- Snapshot model — tenant-curated, immutable, named declarations of `{plugin_id: version, ...}`; live + shadow snapshots running in parallel as independent data planes; promote / reject lifecycle; plugin-shipped migrations between snapshots via cross-snapshot SELECT GRANT
- Trust tier model — vendor-signed / instance-signed / unsigned, with capability matrix
- Baseline isolation — per-install ClickHouse user with scoped GRANTs, NetworkPolicy egress allowlist, ResourceQuota, no K8s API access — applies to every plugin regardless of trust tier
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

- [ ] `p2` - **ID**: `cpt-plugin-fr-oci-artifact`

Every plugin **MUST** be published as an OCI artifact (container image plus manifest metadata) to an OCI-compatible registry. The plugin system **MUST** accept plugins from Docker Hub, ghcr.io, and any registry that speaks the OCI distribution spec, including customer-owned private registries.

**Rationale**: Uniform packaging across first-party, enterprise, and third-party plugins; leverages an already-deployed ecosystem; supports air-gapped installations through registry mirroring.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-oci-registry`

#### Reverse-DNS Naming and SemVer Versioning

- [ ] `p2` - **ID**: `cpt-plugin-fr-naming-versioning`

Every plugin **MUST** be identified by a reverse-DNS identifier (`com.acme.git-gitlab`) that is globally unique across authors. Every published build **MUST** carry a SemVer 2.0 version. The plugin system **MUST** reject installs whose ID collides with an already-installed plugin from a different author.

**Rationale**: Reverse-DNS avoids short-name collisions between independent authors (two different `git` plugins). SemVer gives dependency resolution a principled ordering and a clear breaking-change signal.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-admin-api`

#### Central Catalog and URL Install Coexist

- [ ] `p2` - **ID**: `cpt-plugin-fr-catalog-and-url`

The plugin system **MUST** support two install sources: a curated central catalog (metadata served by the Insight-operated catalog service) and ad-hoc URL install (tenant admin supplies an OCI reference for a plugin that is not in the catalog). Instance admins **SHOULD** be able to restrict their tenants to catalog-only plugins via an instance-level policy.

**Rationale**: Central catalog enables discovery, curation, and compatibility testing for the common case. URL install enables customer-authored plugins that are never intended to be published publicly without requiring a catalog gatekeeping workflow.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-instance-admin`, `cpt-plugin-actor-central-catalog`

#### Declarative Manifest Per Plugin

- [ ] `p2` - **ID**: `cpt-plugin-fr-manifest`

Every plugin **MUST** ship a machine-readable manifest that declares at minimum: reverse-DNS identity, version, human-readable name, description, author/license, supported platform version range, the capabilities it contributes (`connector`, `silver`, `widget`, or any composition), for each capability its data contract (inputs, outputs), config schema, required secrets, and the plugin's dependencies on other plugins. The manifest schema itself is defined in DESIGN.

**Rationale**: The manifest is the contract that dependency resolution, UI form generation, catalog display, and health reporting all depend on. Without a declared manifest, the platform cannot install a plugin safely.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-admin-api`

### 5.2 Snapshot-Based Versioning and Installation

#### Tenant-Scoped Installs

- [ ] `p1` - **ID**: `cpt-plugin-fr-tenant-scoped-installs`

Every plugin install **MUST** be scoped to a single tenant. Two tenants in the same instance running the same plugin **MUST** get independent installs — independent config, independent bronze scope, independent credentials, independent schedule. Instance admins **MAY** restrict the set of plugins available to tenants through allowlists or trust-tier policies (see Section 5.9), but **MUST NOT** install or activate plugins on a tenant's behalf.

**Rationale**: Tenants are the atomic billing and isolation boundary; shared installs break tenant isolation and complicate uninstall.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-instance-admin`

#### Snapshot Is the Unit of Tenant Plugin State

- [ ] `p1` - **ID**: `cpt-plugin-fr-snapshot-as-state`

A tenant's plugin state **MUST** be expressed as a SNAPSHOT — an immutable, named, tenant-owned declaration of `{plugin_id: version, ...}` plus the tenant config and secrets that pin each install. A tenant **MUST** have at most one *live* snapshot at any time (the one that feeds user-facing surfaces) and **MAY** have any number of *shadow* snapshots running alongside (for adaptation, comparison, or experimentation).

Each snapshot **MUST** carry its own DB scope namespace. Per-install scopes are keyed `bronze_<snapshot>_<install>` / `silver_<snapshot>_<install>` so two snapshots are fully independent data planes — no shared tables, no merging, no cross-snapshot interference at runtime. Per-install ClickHouse credentials follow the same scoping (see `cpt-plugin-fr-per-install-db-user`).

A snapshot **MUST** be immutable once published: editing a snapshot means publishing a new snapshot. Tenants iterate by authoring successive snapshots, never by mutating an existing one.

**Rationale**: Lifting the unit of versioning from plugin to snapshot eliminates the runtime resolver's worst case — dependency-hell at install time. The snapshot author resolves all conflicts once, at authoring time; the runtime simply applies the snapshot. The same primitive supports "two versions running in parallel" (the previous *multi-version* requirement), upgrade, rollback, and per-tenant customization, with one mental model instead of four.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-plugin-runtime`

#### Snapshot Authorship Is Tenant-First, Vendor-Optional

- [ ] `p2` - **ID**: `cpt-plugin-fr-snapshot-authoring`

The default and primary author of a tenant's snapshots is the *tenant admin*. The plugin system **MUST** support tenant authoring as a first-class flow — authoring a snapshot is the same kind of operation as authoring any other tenant configuration, not a privileged system-admin operation.

The plugin system **MAY** ALSO support reference snapshots published by other parties (Insight as the vendor; instance admins for an organization-wide internal stack; third parties for community templates). Reference snapshots **MUST NOT** be privileged — they are starting points the tenant admin can clone, modify, or ignore. They are *convenience*, not *governance*. A tenant **MAY** run for the entire lifetime of the instance without ever using a vendor or instance reference snapshot.

**Rationale**: Forcing snapshots through a curator gate would replicate the problem the plugin system was built to solve — vendor coupling. Tenant-first authoring keeps the tenant in control of its own composition. Vendor reference snapshots remain valuable as starting points and as documented "this combination is known to work" recommendations, but never as the only path.

**Actors**: `cpt-plugin-actor-tenant-admin`

#### Tenant Upgrade Sovereignty

- [ ] `p1` - **ID**: `cpt-plugin-fr-tenant-sovereignty`

The plugin system **MUST NOT** allow an instance admin to install, upgrade, reconfigure, enable, or otherwise advance a tenant's snapshot on the tenant's behalf. Instance admins retain oversight powers — trust-tier policy (Section 5.9), catalog allowlists / blocklists, force-retirement of a known-malicious or vulnerable plugin from across all tenants — but every additive change to a tenant's snapshot **MUST** be initiated and approved by a tenant admin. Emergency force-retire by an instance admin **MUST** be recorded in the audit log with the reason and **MUST** notify the tenant admin.

**Rationale**: If a plugin upgrade corrupts tenant data, the party who approved the upgrade must be the one responsible for the data. The instance admin's job is to protect the instance (block dangerous plugins, contain outages), not to push changes into tenants who have not asked for them.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-instance-admin`

#### Shadow-Deploy Snapshot Upgrade with Soft Trial Reminder

- [ ] `p1` - **ID**: `cpt-plugin-fr-snapshot-shadow-deploy`

When a tenant admin upgrades the live snapshot to a new snapshot, the plugin runtime **MUST** install the new snapshot as a *shadow* alongside the live snapshot rather than replacing it in place. Both snapshots **MUST** run concurrently:

- The *live* snapshot continues to feed user-facing surfaces (widgets, analytics-api). No user observes the upgrade until the tenant admin explicitly *promotes* the shadow.
- The *shadow* snapshot processes the same connector inputs into its own per-snapshot scopes, on its own schedules, with its own per-install credentials. Each install in the shadow is an independent install — different `install_id` from any same-plugin install in the live snapshot.

The plugin runtime **MUST** expose a side-by-side comparison view in the admin UI: row counts, schema diffs, and — where the live and shadow tables match in shape — per-column distributional statistics, so the tenant admin can inspect the change on real data before promoting.

The adaptation period is **open-ended**. The system **MUST NOT** auto-promote OR auto-reject when a configurable *trial reminder timer* (default 7 days; tenant-configurable) expires; instead the UI **MUST** raise a non-blocking reminder ("you switched N days ago, ready to retire the old snapshot?"). Subsequent reminders escalate by frequency rather than by action — no plugin or snapshot ever silently promotes itself or silently disappears. The tenant admin always retains the choice and the timing.

When the tenant admin PROMOTES the shadow snapshot, the runtime **MUST** atomically switch the *live* pointer to the new snapshot. The previous (now non-live) snapshot **MAY** continue running for as long as the tenant admin wants, or **MAY** be retired explicitly. Bronze data is retained until explicit retirement (per `cpt-plugin-fr-bronze-preserved`).

When the tenant admin REJECTS the shadow snapshot, the runtime uninstalls it; shadow bronze is discarded since no downstream consumer relied on it.

The plugin system **MUST NOT** expose a distinct "rollback" operation. Reverting a previously-promoted snapshot to its predecessor is accomplished by initiating a new shadow-deploy whose target is the older snapshot (still in the tenant's snapshot history): the same shadow / compare / promote loop applies. There is no asymmetry between forward and backward transitions.

**Rationale**: Open-ended adaptation matches how real teams validate changes — over weeks of business cycles, not on a 7-day timer. The reminder UX prevents tenants from forgetting an old snapshot indefinitely (which would consume storage and operational attention) without removing tenant control. The "no auto-action" rule is the price of `tenant-sovereignty`. Lifting the operation to *snapshot* level (rather than per-plugin shadow) eliminates the question "if two plugin versions coexist, which feeds analytics-api?" — only the *live* snapshot does, by definition.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-plugin-runtime`

#### Cross-Snapshot SELECT GRANT for Migration

- [ ] `p2` - **ID**: `cpt-plugin-fr-cross-snapshot-grant`

When a shadow snapshot is created, the plugin runtime **MUST** grant each install in the shadow snapshot `SELECT` privilege on the corresponding install's bronze scope in the live snapshot, **for the duration of the shadow snapshot's existence and only that duration**. The grant **MUST** be revoked when the shadow snapshot is promoted (after the live pointer moves), rejected, or retired. The grant **MUST NOT** include `INSERT`, `UPDATE`, `DELETE`, or `ALTER` on the live snapshot's scope — read-only.

**Rationale**: Plugin-author-shipped migrations need to read historical bronze from the previous snapshot to populate the new snapshot's scope. Granting time-bounded read access is the minimum viable mechanism: the plugin can author migrations as views or as full-copy SQL (per `cpt-plugin-fr-migration-via-views`), but it is the *runtime* that scopes the grant in time, so an abandoned shadow does not leave a permanent cross-scope hole. Revocation on promotion / rejection / retirement keeps the security surface minimal.

**Actors**: `cpt-plugin-actor-plugin-runtime`

#### Snapshot Inventory in Instance Database

- [ ] `p1` - **ID**: `cpt-plugin-fr-inventory-storage`

The plugin system **MUST** persist the per-tenant snapshot inventory (snapshot ids, plugin set, status — `live`, `shadow`, `retired` — created-at, who-by, the audit log of authoring and promotion events) in the instance database. The inventory **MUST** survive restarts, `helm upgrade` of the Insight umbrella, and reconciliation by the plugin runtime.

**Rationale**: The inventory is the source of truth about a tenant's extension surface. Storing it in the instance DB (not in Kubernetes CRDs) keeps it co-located with tenant data, enables transactional admin-API operations, and simplifies backup.

**Actors**: `cpt-plugin-actor-admin-api`, `cpt-plugin-actor-plugin-runtime`

#### Retired Snapshot Reporting

- [ ] `p2` - **ID**: `cpt-plugin-fr-retired-snapshot-reporting`

The plugin system **SHOULD** identify snapshots that have been non-live for longer than a configurable threshold (default 30 days) and **SHOULD** surface them to the tenant admin as candidates for retirement. The system **MUST NOT** retire them automatically.

**Rationale**: Open-ended adaptation is intentional, but old snapshots that nobody is comparing against waste storage and cognitive load. Surfacing them keeps the tenant in control of cleanup.

**Actors**: `cpt-plugin-actor-tenant-admin`

### 5.3 Connector Capability

#### Connector Normalizes Source Data to a Declared Output Schema

- [ ] `p1` - **ID**: `cpt-plugin-fr-connector-output-contract`

A plugin that declares the `connector` capability **MUST** declare its output as a schema (tables + columns + types) in its manifest and **MUST** guarantee that every row it writes to bronze conforms to that declared schema. The connector **MUST** perform whatever reshaping is required to normalize raw source payloads into the declared shape (pivoting, renaming, type coercion, de-nesting, timestamp normalization, etc.) — it is the connector's responsibility, not the downstream silver plugin's, to absorb the vendor's data quirks.

**Rationale**: Decoupling silver from vendor idiosyncrasies is the architectural intent. If every silver plugin had to parse every connector's raw output, adding a new connector would require changing every silver plugin that consumes it. Pushing normalization into the connector means silver plugins match on shape alone and a new source becomes a drop-in.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Connector Writes to a Per-Install Bronze Scope

- [ ] `p1` - **ID**: `cpt-plugin-fr-connector-bronze-scope`

A connector capability **MUST** write into a per-install bronze scope in the data store, isolated from every other connector install (including other installs of the same plugin for the same tenant at different versions). Tables, schemas, and any other data-store namespace the connector uses **MUST** be derivable from the `(tenant_id, plugin_id, plugin_version, install_id)` tuple so scopes do not collide.

**Rationale**: Bronze is the durable record of what the connector produced after normalization. Isolating scopes by install means uninstalls are safe (delete the scope), migrations between versions are safe (write to a new scope, validate, then switch), and multi-version coexistence works.

**Actors**: `cpt-plugin-actor-plugin-runtime`

#### Bronze Data Is Preserved Across Upgrades

- [ ] `p1` - **ID**: `cpt-plugin-fr-bronze-preserved`

The plugin system **MUST** preserve a connector install's bronze data across plugin upgrades unless the admin explicitly requests its deletion. Connector plugins **MAY** ship forward-only migrations for bronze schema evolution; silver and widget layers are always re-derivable and **MUST NOT** require any such migration.

**Rationale**: Bronze is the only layer not reconstructible from other layers. Losing it means losing history. Keeping it sacred is the single most important data-durability commitment of the plugin system.

**Actors**: `cpt-plugin-actor-plugin-runtime`

#### Connector Execution Protocol Is Author's Choice

- [ ] `p2` - **ID**: `cpt-plugin-fr-connector-protocol-flexibility`

A connector-capability plugin **MAY** be executed using any protocol its author chooses, as long as the running container produces bronze tables in its declared per-install scope. The plugin system **MUST** support the Airbyte source protocol (so that existing Airbyte connectors can be wrapped as Insight plugins with minimal rework) and **MUST** be extensible to other protocols — for example, Singer tap, or a future native Insight connector protocol — as they are adopted.

**Rationale**: Requires zero migration cost for the existing Airbyte connector fleet and avoids locking Insight into a single execution contract for the next decade. The platform's job is to give the connector a scope to write to and collect its output; how it produces that output is a plugin-internal concern.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Airbyte Connectors Reuse the Airbyte Destination for Bronze

- [ ] `p2` - **ID**: `cpt-plugin-fr-airbyte-destination-reuse`

For connector plugins that use the Airbyte source protocol, the plugin system **MUST** support using the existing Airbyte ClickHouse destination to write bronze, rather than reimplementing the destination inside the plugin runtime.

**Rationale**: The Airbyte destination is battle-tested for the types and quirks of ClickHouse ingestion. Reimplementing it for v1 is busywork and a regression risk.

**Actors**: `cpt-plugin-actor-plugin-runtime`

### 5.4 Silver Capability

#### Silver Declares an Input Contract, Not Supplier Plugins

- [ ] `p1` - **ID**: `cpt-plugin-fr-silver-input-contract`

A plugin that declares the `silver` capability **MUST** declare its inputs as a contract consisting of (a) the expected schema (tables, columns, types) of each input and (b) discovery rules (tags, name patterns, or install-time parameters) by which the plugin runtime locates source tables in the data store. The silver plugin **MUST NOT** declare plugin-level dependencies on specific connector plugins for its data sources — compatibility is schema-based, not plugin-identity-based.

**Rationale**: Decoupling silver from specific connectors is the point of the capability boundary. A tenant that adds a third connector (say `git-bitbucket`) producing the expected shape should feed the existing `silver-git` plugin without `silver-git` being aware of it. A connector that upgrades to a new major version without changing the output schema should not trigger a silver-plugin upgrade. Schema-level contracts give this flexibility; plugin-ID dependencies would not.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Silver Produces Declared Output Tables

- [ ] `p1` - **ID**: `cpt-plugin-fr-silver-transform`

A silver-capability plugin **MUST** declare its output silver tables (schema + columns + types) in its manifest and **MUST** produce them in a per-install silver scope. The recommended default processing pattern is `UNION ALL` across all discovered input sources with incremental consolidation, but the plugin **MAY** skip that step and emit pre-aggregated or derived tables directly; the choice is internal to the plugin.

**Rationale**: A silver plugin is in essence a function `(discovered bronze) → silver*`. Declaring the output explicitly is what allows widgets and other downstream consumers to rely on it. Leaving the internal pipeline shape to the plugin author lets complex cases (algorithmic enrichment, cross-entity joins, ML scoring) fit the same contract as simple union-based silvers.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Transformation Engine Is Author's Choice

- [ ] `p2` - **ID**: `cpt-plugin-fr-silver-engine-flexibility`

Silver capability **MUST NOT** constrain the plugin to a specific transformation engine. dbt is the reference engine for the first-party silver plugins; authors **MAY** use Rust, Python, or any other language, provided the container reads the declared bronze inputs and writes the declared silver outputs.

**Rationale**: dbt's model is great for declarative SQL transforms but breaks down for algorithmic enrichment (identity resolution, ML scoring, custom aggregations). Forcing every silver plugin into dbt would either lock those cases out or contort them. Letting authors pick the engine keeps the capability broad.

**Actors**: `cpt-plugin-actor-plugin-author`

#### Silver Consumer Validates Its Inputs

- [ ] `p2` - **ID**: `cpt-plugin-fr-silver-consumer-validates`

A silver plugin **MAY** ship data-quality tests against its declared bronze inputs (dbt tests for dbt-based plugins; equivalent mechanism in the manifest for other engines). When such tests are present, the plugin runtime **MUST** execute them before running the transform and **MUST** report failures to the admin.

**Rationale**: Connectors evolve independently of silver plugins. The only robust defense against "connector sent us garbage today" is for the silver consumer to declare its expectations and check them before transforming. Shifts responsibility for compatibility to the party best positioned to enforce it.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Plugin Ships Its Own Migrations (Optionally as Cross-Snapshot SQL Views)

- [ ] `p2` - **ID**: `cpt-plugin-fr-migration-via-views`

A plugin **MAY** ship migration scripts that the runtime runs when a new snapshot containing this plugin is created and a previous snapshot containing the same plugin (under the same `plugin_id`, possibly at a different version) exists. Migrations **MAY** be expressed in any of the following forms; the choice is the plugin author's:

- **`CREATE VIEW`** in the new install's scope, reading from the previous install's bronze through the cross-snapshot SELECT grant (`cpt-plugin-fr-cross-snapshot-grant`). Zero storage cost; reads pay view-evaluation overhead. Suitable when historical data shape changes are minor renames / casts / computed columns.
- **`CREATE MATERIALIZED VIEW`**, populated as a background job. Storage proportional to historical data; reads cheap after materialization. Suitable when downstream silver / widgets need indexed or projection-optimized access.
- **`INSERT FROM SELECT`** (full physical migration). Run once during shadow installation; the cross-snapshot grant is no longer needed after completion. Storage proportional to historical data; full control of target shape.
- **No migration**: the plugin starts with an empty bronze scope; historical data does not carry over. Acceptable for connectors that re-fetch from the upstream source on schedule.

The plugin runtime **MUST** make the prior snapshot's bronze scope name available to the migration script as a parameter and **MUST** revoke the cross-snapshot grant when the shadow snapshot is promoted, rejected, or retired.

**Rationale**: Plugin authors are the only party who knows whether a schema change is a rename, a derivation, a destructive transformation, or a from-scratch reconnect. Letting the author pick the migration form (and pay the storage cost they choose) keeps the system honest about the cost-vs-richness tradeoff. View-based migrations in particular keep the storage cost of a long-running shadow snapshot at `~1× + delta` instead of `2×` — the concern raised in PR review (storage explosion with multi-snapshot coexistence) becomes a function of plugin-author choice, not a system-imposed worst case.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Each Plugin Ships Its Own Isolated Transform Project

- [ ] `p1` - **ID**: `cpt-plugin-fr-isolated-transform-project`

A plugin that performs transformations (connector normalization, silver transform, or any future transform capability) **MUST** ship its transformation code as a SELF-CONTAINED project scoped to its plugin directory — its own `dbt_project.yml`, its own `packages.yml`, its own macros and models, or the equivalents of another engine. Plugins **MUST NOT** use dbt `ref()` (or the equivalent cross-project reference mechanism of another engine) to reach into another plugin's models. The only supported cross-plugin data flow is via ClickHouse tables materialized by an upstream plugin and referenced by a downstream plugin as dbt `source()` (or equivalent) through the schema-based input contract (`cpt-plugin-fr-silver-input-contract`).

The plugin runtime **MUST** render source definitions (e.g., `sources.yml` for dbt plugins) with the concrete schema names resolved from the discovery rules at run time, injecting them into the plugin's transform project before each run. A plugin **MUST NOT** hardcode schema names that assume a specific upstream plugin install, and the plugin system **MUST NOT** construct a global transform DAG spanning plugins; each install runs its own transform end-to-end, on its own schedule, in isolation.

**Rationale**: A shared transform DAG (such as a single repo-wide dbt project) couples every plugin to every other plugin at compile time — one plugin's rename or type change compiles-fails a completely different plugin owned by a different author. Project-per-plugin isolation is what enables independent authorship, independent versioning, independent release cadence, independent runtime upgrade (including shadow-deploy), and the eventual path to third-party plugins. The cost is losing dbt's ability to order transforms across plugins — but cross-plugin ordering belongs at the system scheduling layer (cron + discovery-based source resolution), not inside the transform engine.

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

### 5.5 Widget Capability

#### Widget Ships as a Microfrontend Module

- [ ] `p2` - **ID**: `cpt-plugin-fr-widget-microfrontend`

A plugin that declares the `widget` capability **MUST** ship a microfrontend module that the Insight host frontend loads at runtime. The host frontend **MUST** fetch the module on demand — widgets are not bundled into the product build — and **MUST** render the module within the container-provided frame.

**Rationale**: Runtime-loaded widgets are the only way to extend the dashboard surface without a frontend rebuild. Microfrontend is the contract the rest of the frontend is already moving toward; reusing it here means widget-capability plugins do not need a separate runtime.

**Actors**: `cpt-plugin-actor-plugin-runtime`

#### Widget Receives Data from the Host App

- [ ] `p2` - **ID**: `cpt-plugin-fr-widget-data-contract`

A widget capability **MUST** declare its expected input data as a table schema (column names, types, nullability) and optional config (JSON schema). The host application **MUST** resolve the data based on the dashboard's widget-instance configuration, fetch it, and pass it to the widget through a stable interface. The widget **MUST NOT** query the data store directly. The host **MUST** act as a pass-through — it **MUST NOT** validate that the delivered data matches the widget's declared schema.

**Rationale**: Centralizing data fetching in the host prevents widget plugins from leaking data between tenants, bypassing isolation, or holding long-lived DB credentials. Keeping the host a pure proxy (no semantic validation) avoids accidentally coupling the host to every widget's evolving schema; validation, when needed, belongs to the party that cares — the widget plugin itself (see `cpt-plugin-fr-widget-input-tests`).

**Actors**: `cpt-plugin-actor-plugin-author`, `cpt-plugin-actor-plugin-runtime`

#### Widget Input Validation Is Opt-In via Plugin-Shipped Tests

- [ ] `p2` - **ID**: `cpt-plugin-fr-widget-input-tests`

A widget-capability plugin **MAY** ship data-quality tests (dbt or an equivalent mechanism declared in the manifest) against its declared input. When such tests are present, the plugin runtime **MUST** execute them before rendering the widget and **MUST** surface failures to the admin. When such tests are not present, the host renders whatever it fetched without checking it.

**Rationale**: Data-shape mismatches break widgets silently today. Letting widget authors declare and enforce their own expectations shifts responsibility to the party who feels the pain. Keeping tests opt-in avoids forcing every trivial widget to invent a test suite.

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

- [ ] `p2` - **ID**: `cpt-plugin-fr-semver-contracts`

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

Plugin capabilities that require secrets (API tokens, credentials) **MUST** declare them in the manifest. The plugin system **MUST** support providing them through:

- **(a) An external secret manager**, configured at the instance level. Supported integrations include — at minimum — HashiCorp Vault, External Secrets Operator (which itself bridges to AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, etc.), and SealedSecrets for GitOps-managed deployments. The exact set of supported integrations is a DESIGN decision; the contract is that the plugin manifest names a secret by reference, not by value.
- **(b) A manual entry path in the admin UI** for instances without an external store wired up. The submitted value is encrypted at rest in the instance's K8s `Secret` (or equivalent), scoped to the install.

Secrets **MUST NOT** be logged, leaked into manifests, included in audit-log payloads beyond a redacted reference, or stored in the catalog. Secrets **MUST** be rotated atomically — a rotation produces a new version of the secret which the runtime injects into newly-spawned plugin pods on next sync.

**Rationale**: Enterprise customers expect Vault / cloud-vendor managers; small deployments need a fallback that does not require that infrastructure. Both paths are common, and the split keeps each simple. Naming concrete integration points (rather than the vague "external secret manager") closes a clarification raised in review.

**Actors**: `cpt-plugin-actor-tenant-admin`, `cpt-plugin-actor-instance-admin`

#### Per-Install ClickHouse User with Scoped GRANTs

- [ ] `p1` - **ID**: `cpt-plugin-fr-per-install-db-user`

Every plugin install **MUST** be assigned a dedicated ClickHouse user, generated by the plugin runtime at install time with a cryptographically random password stored as a K8s `Secret` (or equivalent) and injected into the plugin pod via env. The plugin **MUST NOT** use the ClickHouse `default` user, an admin user, or the credentials of any other install. The plugin runtime **MUST** provision GRANTs scoped to the install's capability:

- **Connector install**: `INSERT, SELECT, ALTER ON bronze_<snapshot>_<install>.*` (its own bronze scope only).
- **Silver install**: `SELECT ON bronze_<snapshot>_<discovered_input>.*` for each upstream bronze scope resolved through the schema-based input contract (`cpt-plugin-fr-silver-input-contract`); plus `INSERT, SELECT, ALTER ON silver_<snapshot>_<install>.*` for its own silver scope.
- **Widget install**: no direct ClickHouse access. Widgets read data through the host application (`cpt-plugin-fr-widget-data-contract`).
- **Cross-snapshot SELECT** for the duration of a shadow snapshot's life, per `cpt-plugin-fr-cross-snapshot-grant`.

The runtime **MUST** revoke all GRANTs and drop the user when the install is uninstalled (snapshot retired). The runtime **MUST** support per-user query and resource quotas (max queries per minute, max memory per query) configured at install time and capped by instance-admin-level defaults.

**Rationale**: A plugin holding broad ClickHouse credentials can read any tenant's data, write into any tenant's scope, enumerate `system.tables`, and pivot via stored procedures regardless of any application-level policy. Per-install scoped GRANTs make those misuses *cryptographically impossible* at the database layer rather than enforced by application code. Closes the data-plane access concerns raised in review.

**Actors**: `cpt-plugin-actor-plugin-runtime`, `cpt-plugin-actor-tenant-admin`

### 5.8 Observability and Lifecycle

#### Plugins Report Operational Status

- [ ] `p2` - **ID**: `cpt-plugin-fr-status-reporting`

Every installed plugin **MUST** report its operational status to the plugin runtime: connector sync progress and errors, silver transform run outcomes and data-test failures, widget render failures. The plugin system **MUST** make this status available to the instance admin through the admin UI.

**Rationale**: Without telemetry flowing back, "the dashboard is wrong" degenerates into a manual hunt across four systems. Centralizing status inside the plugin inventory gives admins a single pane of glass.

**Actors**: `cpt-plugin-actor-plugin-runtime`, `cpt-plugin-actor-instance-admin`

#### Dependency Graph Surfaced to Admins

- [ ] `p2` - **ID**: `cpt-plugin-fr-dep-graph-ui`

Instance admins **SHOULD** be able to view the dependency graph across all installed plugins with per-node health state (healthy, degraded, broken, upgrade available, in-shadow-trial). Tenant admins **SHOULD** see the subset of the graph relevant to their tenant, including any shadow-deploy trials currently in flight.

**Rationale**: Plugin ecosystems grow dense fast, and the system is explicitly non-auto-healing (no legacy mode, no silent rollback) — failures and conflicts must be investigated by a human. A visual graph is a scalable way to find "what is broken and what does it block." Note: the side-by-side **comparison view** during a shadow-deploy trial is a separate `MUST` already covered by `cpt-plugin-fr-snapshot-shadow-deploy`; this FR is the broader cross-plugin / cross-tenant graph, kept at `SHOULD` because a flat list view of installs with health badges is sufficient for v1 operability. A graph visualization is the right long-term shape but not release-gating.

**Actors**: `cpt-plugin-actor-instance-admin`, `cpt-plugin-actor-tenant-admin`

#### End-User Error Surface Is Minimal

- [ ] `p2` - **ID**: `cpt-plugin-fr-end-user-error`

Non-admin users **MUST NOT** be exposed to plugin-internal error detail. When plugin state prevents a dashboard or widget from rendering accurately, end users **MUST** see a generic "data temporarily unavailable" indicator; plugin-level diagnostics are surfaced only to admins.

**Rationale**: End users cannot act on plugin stack traces. Showing them is both a security concern (leaks plugin internals) and a UX regression.

**Actors**: `cpt-plugin-actor-plugin-runtime`

### 5.9 Security and Trust Model

#### Image Signing and Digest Pinning Are Required

- [ ] `p1` - **ID**: `cpt-plugin-fr-image-signing-required`

Every plugin install **MUST** reference its container image by **digest** (`@sha256:<...>`) — never by mutable tag. The plugin runtime **MUST** reject any install whose manifest pins the image by tag alone. Every install **MUST** also be accompanied by a cryptographic signature over that digest (Sigstore / cosign or equivalent). The plugin runtime **MUST** verify the signature against the configured trust roots (see `cpt-plugin-fr-trust-tiers`) at install time and at every pod admission, and **MUST** reject pods whose image digest does not match a verified signature.

The plugin runtime **MUST** support a revocation list (Sigstore transparency log + locally-cached revocation entries from configured signing authorities). A revoked digest **MUST** prevent further pod admissions for that image, even if the install was created before revocation.

**Rationale**: Mutable tags are how supply-chain attacks slip in: republish under the same tag, the next pull picks up the malicious image. Pinning by digest forecloses this. Signature verification ensures the digest we install is the digest the author intended to ship. Revocation closes the window between "we discovered the key was compromised" and "every running deployment stops trusting it." All three together are the minimum viable supply-chain defense for a system that runs third-party code with cluster-internal data access.

**Actors**: `cpt-plugin-actor-plugin-runtime`, `cpt-plugin-actor-plugin-author`

#### Trust Tiers Modulate Capabilities Above a Common Baseline

- [ ] `p1` - **ID**: `cpt-plugin-fr-trust-tiers`

The plugin system **MUST** classify every plugin install into one of three trust tiers, based on whose key signed the image:

- **Vendor-signed**: signed by Insight's official signing key, distributed in the instance's bundled trust roots.
- **Instance-signed**: signed by a key the instance admin has explicitly registered as an additional trust root for this instance (used for in-house plugins authored by the customer's own engineering org).
- **Unsigned**: any install whose signature does not chain to a configured trust root. Unsigned installs are still allowed (this is not a gate on installation), but they run in a more restricted capability profile.

The capability profile **MUST** modulate the following dimensions per tier; baseline isolation (`cpt-plugin-fr-baseline-isolation`) applies regardless of tier:

| Dimension | Vendor-signed | Instance-signed | Unsigned |
|---|---|---|---|
| Image registry | any registry on the instance allowlist | any registry on the instance allowlist | Insight-curated allowlist only |
| Image-scan policy | required (Trivy / Grype or equivalent) | required | required + size limit |
| Widget render mode | native React component (full DOM) | native | cross-origin iframe with `sandbox` attribute; communicates via `postMessage` only |
| Widget access to user JWT | through host SDK proxy | through host SDK proxy | **never** — JWT is never exposed cross-origin |
| Silver execution engine | any (dbt / Rust / Python / WASM) | any | dbt only |
| Container runtime class | runc | runc | gVisor or Kata (kernel isolation) |
| Egress proxy strictness | manifest allowlist accepted | manifest allowlist accepted | manifest allowlist + tenant-admin approve at install |
| Cross-snapshot SELECT GRANT (for migrations) | granted automatically | granted automatically | requires explicit tenant-admin approval per install |

**Rationale**: Trust modulates the *delta above baseline*, not whether the plugin can run at all. Two-tier "trusted vs untrusted" is too coarse for enterprise — internal plugins authored by the customer's own engineering org need higher capabilities than community plugins, but the customer cannot get the vendor's signing key. Three tiers map to three real authoring contexts (vendor / customer / community). The capability matrix is fixed in the PRD so it is auditable and not negotiable per-deployment; the alternative — "instance admin chooses which capabilities each tier gets" — yields too many configuration surfaces and incident vectors.

**Actors**: `cpt-plugin-actor-plugin-runtime`, `cpt-plugin-actor-instance-admin`

#### Baseline Isolation Applies to Every Plugin Regardless of Trust Tier

- [ ] `p1` - **ID**: `cpt-plugin-fr-baseline-isolation`

Independent of trust tier, every plugin install **MUST** run under the following baseline isolation. None of these may be relaxed by signing.

- **ClickHouse access**: per-install user with capability-scoped GRANTs only (`cpt-plugin-fr-per-install-db-user`). The `default` user is forbidden.
- **Network egress**: a `NetworkPolicy` derived from the manifest's declared egress allowlist is applied to the plugin's pods. Outbound to anything not on the allowlist is dropped at the network layer. There is no "trusted plugin can talk to anywhere" mode — every egress destination is declared and visible to the admin.
- **Compute quotas**: CPU and memory `requests` / `limits` from the manifest, capped by per-tenant and per-instance defaults configured by the instance admin. A single plugin cannot DoS the cluster regardless of its provenance.
- **Kubernetes API access**: the default `ServiceAccount` for plugin pods has no role bindings — the plugin cannot list pods, read secrets it does not own, or interact with the K8s API in any way. Plugins that need to spawn jobs (e.g., to invoke Argo) do so through the plugin runtime's API, not directly against the K8s API.
- **Filesystem**: pod root filesystem is read-only; only declared volume mounts (typically a per-install `emptyDir` for transient data) are writable.
- **Per-install bronze / silver scopes**: each install writes only into its own scope (`bronze_<snapshot>_<install>`, `silver_<snapshot>_<install>`). Cross-scope writes are not possible because the per-install GRANTs do not cover them.
- **No host networking, no privileged containers, no `hostPath` mounts.**

**Rationale**: Trust-tier modulation is meaningful only on top of a credible baseline. A "trusted" plugin that can't run a backdoor egress is still trustworthy because of the baseline; an "untrusted" plugin that *can* run a backdoor egress is dangerous regardless of tier. The baseline is the foundation; tiers are the delta.

**Actors**: `cpt-plugin-actor-plugin-runtime`, `cpt-plugin-actor-instance-admin`

#### Connector Schema Conformance Enforced at Write

- [ ] `p2` - **ID**: `cpt-plugin-fr-connector-schema-conformance`

The plugin runtime **MUST** enforce the connector's declared output schema (`cpt-plugin-fr-connector-output-contract`) at write time: rows that do not conform to the declared columns and types **MUST** be rejected and surfaced as a connector failure. The runtime **SHOULD** support this via a schema-validating proxy or a ClickHouse table schema that mirrors the manifest exactly.

**Rationale**: The silver-side `cpt-plugin-fr-silver-consumer-validates` defends the consumer; this FR defends the producer. A connector that emits malformed rows by accident or malice should fail loudly at write rather than corrupt bronze and require the silver tests to catch the symptom downstream.

**Actors**: `cpt-plugin-actor-plugin-runtime`, `cpt-plugin-actor-plugin-author`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Install-to-Functional Time

- [ ] `p2` - **ID**: `cpt-plugin-nfr-install-latency`

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

- [ ] `p2` - **ID**: `cpt-plugin-interface-catalog-api`

**Type**: REST API (read-only for tenant admins; read/write for instance admins)

**Stability**: stable

**Description**: Lists plugins available for install (merged view of central catalog + instance-local overrides + URL-installable check). Exposes plugin identity, available versions, description, declared capabilities, and compatibility range. The exact endpoint shape, pagination, and response payload are specified in DESIGN.

**Breaking Change Policy**: Additive fields non-breaking. Removing or renaming fields is a major version bump with a two-minor-release deprecation window.

#### Plugin Install API

- [ ] `p2` - **ID**: `cpt-plugin-interface-install-api`

**Type**: REST API (tenant admin + instance admin)

**Stability**: stable

**Description**: CRUD on installed plugins: request install, approve a resolved plan, upgrade, downgrade, enable, disable, uninstall. Every mutation produces an auditable event; every install change is presented as a resolved plan first and only applied on explicit approval.

**Breaking Change Policy**: Same as catalog API.

#### Plugin Runtime Interface

- [ ] `p2` - **ID**: `cpt-plugin-interface-runtime`

**Type**: Internal interface between the admin API and the plugin runtime

**Stability**: unstable (v1); target stable by v2

**Description**: Describes how a requested install/upgrade/uninstall is reconciled into runtime state — fetching the image, running the capability entrypoints, registering widgets with the frontend, surfacing status. Shape is defined in DESIGN.

### 7.2 External Integration Contracts

#### OCI Registry Contract

- [ ] `p2` - **ID**: `cpt-plugin-contract-oci`

**Direction**: required from external registry

**Protocol/Format**: OCI distribution spec v1.

**Compatibility**: Any registry that speaks OCI v1 works. Private registries require a pull credential configured at the instance level.

#### Plugin Capability Contracts

- [ ] `p2` - **ID**: `cpt-plugin-contract-capabilities`

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

### UC-003 Tenant Admin Promotes a New Snapshot

**ID**: `cpt-plugin-usecase-snapshot-shadow-deploy`

**Actor**: `cpt-plugin-actor-tenant-admin`

**Preconditions**: A live snapshot exists for the tenant. The tenant admin has authored a new snapshot (either by editing the live one and saving as a new snapshot, by cloning a vendor or instance reference, or by composing from scratch).

**Main Flow**:

1. Admin selects "deploy as shadow" on the new snapshot
2. Plugin runtime instantiates the new snapshot as a *shadow*: provisions per-install ClickHouse users with scoped GRANTs (per `cpt-plugin-fr-per-install-db-user`), grants each shadow install `SELECT` on the corresponding live install's bronze (per `cpt-plugin-fr-cross-snapshot-grant`), creates the new bronze / silver scopes, schedules the shadow plugins' work
3. For each plugin in the shadow whose `plugin_id` was also present in the live snapshot, the runtime executes the plugin-author-shipped migration (per `cpt-plugin-fr-migration-via-views`) to populate or expose historical bronze — view, materialized view, full copy, or no migration at the author's choice
4. Both snapshots run concurrently. The live snapshot continues to feed widgets and analytics-api; the shadow snapshot processes the same connector inputs into its own scopes
5. The admin UI exposes a side-by-side comparison view: row counts per silver table, schema diffs, per-column distributional statistics where shapes match (`cpt-plugin-fr-snapshot-shadow-deploy`)
6. Adaptation is open-ended. The trial reminder timer (default 7 days, tenant-configurable) surfaces a non-blocking reminder if the shadow has not been promoted or rejected. Reminders escalate by frequency, never by action (`cpt-plugin-fr-snapshot-shadow-deploy`)
7. The admin PROMOTES — the runtime atomically switches the *live* pointer to the new snapshot, revokes the cross-snapshot GRANT, and the previous (now non-live) snapshot is retained until explicitly retired
8. Inventory is updated; the graph view reports green on the new live snapshot

**Postconditions**: On promote — the new snapshot is live; the previous snapshot remains running but no longer feeds users; bronze of the previous snapshot is retained until explicit retirement (`cpt-plugin-fr-bronze-preserved`). On reject — the shadow snapshot is uninstalled; its bronze is discarded since no downstream consumer relied on it; the tenant remains on the unchanged live snapshot.

**Alternative Flows**:

- **Admin rejects at step 1**: No state change. The new snapshot is saved but not deployed; admin can deploy or discard later.
- **A plugin in the shadow fails to install or migrate**: The runtime surfaces the failure; **the live snapshot is untouched**. Admin can retry, edit the snapshot, or discard the shadow.
- **Admin REJECTS during adaptation (step 6)**: Runtime uninstalls the shadow snapshot, drops its DB scopes, revokes the cross-snapshot GRANT. Tenant remains on the unchanged live snapshot.
- **Trial reminder expires without action**: UI raises a reminder; **no automatic promote, no automatic revert**. The shadow remains running until the admin acts. If the tenant prefers fewer notifications, the reminder cadence is configurable.
- **Reverting a previously-promoted snapshot**: This is not a distinct "rollback" operation. The admin starts a new shadow-deploy targeting the prior snapshot (still in the tenant's snapshot history), and follows the same flow. There is no asymmetry between forward and backward transitions.

### UC-004 Silver Plugin Consumes Bronze from a Connector Plugin

**ID**: `cpt-plugin-usecase-silver-consumes-bronze`

**Actor**: `cpt-plugin-actor-plugin-runtime`

**Preconditions**: A connector plugin and a silver plugin are both installed in the same tenant; the connector's output bronze schema matches the silver plugin's declared input contract (per `cpt-plugin-fr-silver-input-contract`). There is **no** plugin-level dependency declared between them — the match is schema-based, so the same silver plugin accepts any connector whose output shape satisfies its input contract.

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
- **A new connector with matching `output.tag` is added to the same snapshot**: Silver discovery picks it up automatically on the next run — silver is not aware of which specific connector plugin produced the bronze, only of the schema and tag. No silver-plugin change is required when a new compatible connector is added.

### UC-005 Tenant Admin Authors a Custom Snapshot

**ID**: `cpt-plugin-usecase-tenant-snapshot-authoring`

**Actor**: `cpt-plugin-actor-tenant-admin`

**Preconditions**: The tenant admin wants a plugin combination not available as a vendor or instance reference snapshot.

**Main Flow**:

1. Admin opens the snapshot editor in the admin UI
2. Admin starts from a fresh canvas, from a clone of the live snapshot, or from a clone of a vendor / instance reference snapshot
3. Admin adds, removes, or version-pins individual plugins (the catalog UI surfaces available versions and trust tiers per plugin)
4. Admin saves the composition as a new snapshot (immutable; subsequent edits produce a new snapshot, not a mutation)
5. Admin deploys the new snapshot as a shadow per UC-003

**Postconditions**: A new tenant-owned snapshot is recorded in inventory. The tenant can deploy it now or later. Other snapshots in the tenant's history remain unchanged.

**Alternative Flows**:

- **Composition contains a plugin combination flagged by static checks (e.g., two plugins sharing the same `output.tag` in incompatible ways)**: The editor surfaces the issue at save time; the admin can either resolve and resave, or save with a warning. There is no system veto — warnings are non-blocking, but visible.
- **Composition includes an unsigned plugin while instance policy disallows unsigned plugins (per `cpt-plugin-fr-trust-tiers`)**: Save succeeds, deploy is blocked at the instance level until policy is changed or the plugin is replaced.

## 9. Acceptance Criteria

- [ ] A plugin with `connector` capability can be published to an OCI registry and added to a tenant snapshot through the admin UI, end to end, with no code changes to the Insight product
- [ ] A silver plugin whose input discovery yields zero matching bronze tables in the snapshot is installable but surfaces a "no sources discovered" warning to the admin; adding a second connector that produces the expected shape to the same snapshot makes the silver plugin's transform run without modifying the silver plugin
- [ ] An instance admin cannot install or upgrade a plugin on a tenant's behalf, nor mutate a tenant's snapshot, through the admin API; force-retire of a known-bad plugin is allowed and is audit-logged with the reason and tenant notification
- [ ] A plugin that combines `connector` + `silver` + `widget` in a single manifest installs as one artifact and each capability becomes operational independently
- [ ] Two snapshots can coexist in one tenant indefinitely as fully independent data planes (independent bronze / silver scopes, independent per-install ClickHouse users, independent pods); promoting one does not delete the other
- [ ] Promoting a new snapshot retains the previous snapshot's bronze until the admin explicitly retires it
- [ ] A new snapshot installed as a shadow alongside a live snapshot processes the same connector inputs, exposes a side-by-side comparison view, and never feeds user-facing surfaces until promoted
- [ ] A trial reminder timer expires without admin action surfaces a reminder in the UI; no automatic promote, no automatic revert
- [ ] Reverting a previously-promoted snapshot is performed by initiating a new shadow-deploy targeting the prior snapshot — there is no distinct "rollback" API
- [ ] Each plugin's transform code (dbt project or equivalent) is self-contained in the plugin directory; attempting to use dbt `ref()` to reach across plugins fails at compile time; a downstream plugin discovers upstream outputs only through the schema-based input contract with runtime-injected `sources.yml`
- [ ] A plugin install runs under a per-install ClickHouse user with GRANTs scoped to its own bronze / silver scope (and to discovered upstream bronze for silver); attempting to read or write outside the scope is rejected at the database layer
- [ ] A shadow snapshot's installs receive `SELECT` GRANT on the live snapshot's matching bronze for the duration of the shadow only; the GRANT is revoked atomically on promote, reject, or retire
- [ ] A plugin install attempted with an image referenced by tag (no digest) is rejected at install time
- [ ] A plugin install whose image signature does not chain to a configured trust root is allowed in the unsigned tier with reduced capabilities (iframe widget render, dbt-only silver, gVisor / Kata runtime, curated-registry-only)
- [ ] A revoked image digest cannot start new pods even if the install was created before revocation
- [ ] A connector plugin using the Airbyte source protocol can be installed without the plugin author reimplementing destination logic
- [ ] A widget plugin loads in the host frontend at runtime without a product rebuild
- [ ] When a silver plugin's data-quality tests fail, the transform does not run and an admin-visible failure is recorded
- [ ] An instance admin can inspect the inventory of all installed plugins across all tenants with per-install health state and per-snapshot grouping (a flat list view satisfies this; a graph visualization is a `SHOULD` per `cpt-plugin-fr-dep-graph-ui` and is not release-gating)
- [ ] Attempting to install a plugin whose manifest is invalid (missing required fields, malformed schema) fails at the admin-API layer with a clear error, before any runtime action
- [ ] All plugin-produced tables are reachable only through the install's per-install user with scoped GRANTs; cross-tenant and cross-install reads are rejected at the database layer, not merely filtered by application code

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| OCI-compatible registry | Hosts plugin images. Must be reachable from the instance or mirrored for air-gapped installs. Mutable tags are not used — images are pinned by digest | p1 |
| Sigstore / cosign infrastructure | Image signing and verification, transparency log, revocation list distribution | p1 |
| Instance database (MariaDB) | Stores the per-tenant snapshot inventory, snapshot composition, install config, audit log | p1 |
| ClickHouse | Hosts per-snapshot bronze / silver scopes; per-install user RBAC (GRANT/REVOKE), quotas | p1 |
| Plugin runtime subsystem | Reconciles snapshot inventory into runtime state (Kubernetes workloads, K8s `NetworkPolicy`, ServiceAccount, ResourceQuota), frontend widget registration | p1 |
| Kubernetes `NetworkPolicy` controller | Enforces egress allowlist for plugin pods (baseline isolation) | p1 |
| Container runtime classes | Standard `runc` plus `gVisor` or `Kata` available for unsigned-tier plugins; required for kernel isolation | p2 (only needed once unsigned-tier ships) |
| Ingestion orchestration (Argo Workflows today) | Schedules connector syncs and silver transforms; called by the plugin runtime | p1 |
| Host frontend microfrontend loader | Required for native widget render in vendor- / instance-signed tiers; iframe render in unsigned tier works without it | p2 (widget capability ships when this is available) |
| External secret manager | Provides plugin credentials in production; supported integrations include Vault, External Secrets Operator (bridging to AWS / GCP / Azure secret managers), SealedSecrets. Manual-entry fallback for evaluation deployments | p1 (manual-entry suffices for v1, external store is required for prod-grade installs) |
| Central catalog service | Hosts plugin and (optionally) reference-snapshot metadata; URL install works without it | p2 |

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
| Plugin authors misuse SemVer, shipping breaking changes as minor versions | Silent downstream breakage across tenants | Snapshot-as-state model: tenant validates the new snapshot in shadow before promoting, on real data, against the old snapshot side-by-side. SemVer hygiene is helpful but no longer load-bearing; consumer plugins ship data-quality tests as the last line of defense |
| Connector plugins write garbage bronze — typo, API change, malicious plugin — and silver consumers can't tell | Silver / gold layers quietly corrupt | Connector schema conformance enforced at write (`cpt-plugin-fr-connector-schema-conformance`); silver consumers additionally ship data-quality tests against declared input contracts (`cpt-plugin-fr-silver-consumer-validates`); plugin system runs them pre-transform and halts on failure |
| OCI registry is the single point of failure for install and upgrade | Plugin system unavailable when registry is down | Air-gapped path supports mirroring; instance admins can cache plugin images locally; install is idempotent so retry is safe |
| Plugin image is swapped under the same tag (supply-chain attack) | Malicious code lands on next pull | Images are pinned by digest, never by tag (`cpt-plugin-fr-image-signing-required`); signature verification on every pod admission |
| Plugin signing key (vendor or instance) is compromised | All plugins signed by that key become suspect | Sigstore transparency log + revocation list checked on pod admission; per-version signatures so revoking one version does not revoke all; key rotation procedure documented and exercised quarterly |
| Plugin reverse-DNS naming collides across registries (`com.cyberfabric.gitea` on dockerhub vs ghcr.io) | Tenant could install the wrong artifact | Trust tier requires signature; instance admin's curated registry allowlist prevents arbitrary registries for vendor-signed and instance-signed tiers; for unsigned, Insight-curated allowlist only |
| Plugin runtime crash leaves an install in a half-applied state | Manual recovery required | Every install/upgrade plan is persisted before application; runtime is reconciliation-based, so restart resumes from persisted state |
| Plugin attempts cross-tenant data access through DB | Tenant data leakage | Per-install ClickHouse user with GRANTs scoped to install's own bronze / silver and (for silver) discovered upstream bronze; cross-snapshot / cross-tenant reads are physically impossible at the DB layer, not just filtered by application code (`cpt-plugin-fr-per-install-db-user`) |
| Widget plugin escapes its sandbox and accesses user JWT or tenant data | Authentication / data leakage | Widget never queries the data store directly; for unsigned plugins the widget renders in a cross-origin iframe with `sandbox` and the user JWT is never exposed across the iframe boundary (`cpt-plugin-fr-trust-tiers`); for signed plugins, host SDK proxy is the only data path |
| Plugin pod runs scanners, miners, reverse VPN, or other unintended workloads inside the cluster | Compute theft / lateral movement | NetworkPolicy limits egress to manifest-declared targets; ResourceQuota caps CPU/memory; default ServiceAccount has no K8s API access; for unsigned plugins, gVisor/Kata runtime adds kernel isolation (`cpt-plugin-fr-baseline-isolation`) |
| Third-party plugin becomes unmaintained and no one upgrades it past a breaking platform version | Tenants stuck, cannot upgrade platform | Tenant snapshots pin specific digest+signature, so an abandoned plugin keeps working at its pinned version; new platform versions document compatibility windows; abandoned plugins flagged in catalog, not auto-removed |
| Storage cost balloons if many shadow snapshots accumulate over months/years | Disk exhaustion, query slowdown | View-based migrations keep storage at `~1× + delta` instead of `2×` (`cpt-plugin-fr-migration-via-views`); retired-snapshot reporting (`cpt-plugin-fr-retired-snapshot-reporting`) surfaces stale snapshots to admin for cleanup; bronze retention is admin-controlled, not auto |
| Tenant admin loses track of which old snapshots are still alive | Unbounded resource consumption, audit confusion | Snapshot inventory exposes `live` / `shadow` / `retired` status per snapshot; retired-snapshot reporting nudges cleanup; dependency graph view groups installs by snapshot |
| Plugin runtime egress through manifest allowlist is bypassed by DNS exfiltration or covert channels | Data leakage | Egress proxy enforces allowlist at L7 where possible; baseline only — does not claim defense against sophisticated covert channels. Documented limitation: instance admins should use cluster-level egress monitoring for residual coverage |
| GDPR / compliance erasure conflicts with bronze-is-sacred | Regulatory exposure | Bronze-is-sacred is a plugin-system guarantee, not a compliance guarantee; GDPR erasure is handled by a platform-level data-lifecycle tool that can drop a tenant's snapshot scopes on lawful request — not part of this PRD |

## 13. Open Questions

| Question | Owner | Target Resolution |
|----------|-------|-------------------|
| Plugin manifest schema — exact YAML shape, required vs optional fields, how capabilities are expressed, extension points for future capability kinds | Backend tech lead + Plugin Author lead | DESIGN / first ADR |
| Snapshot manifest format — what does a snapshot literally look like on disk (`{plugin_id: digest, version}` list? full plugin manifest copies? something dbt-package-like?) and how is it stored / diffed in the instance database | Backend tech lead | DESIGN |
| Snapshot inheritance and overlays — does a tenant snapshot reference a parent snapshot with overrides ("vendor reference + 3 plugin overrides"), or is every snapshot a flat list? Influences storage and UI complexity | Backend tech lead + Product design | DESIGN, before tenant-snapshot-editor UI ships |
| Vendor reference snapshots — do we ship them at all? If yes, what is the publishing process, the testing matrix, and the maintenance commitment? If no, document explicitly and rely on community / instance-admin reference snapshots only | Insight Product Team | Before v1 ship |
| Snapshot retirement policy — when does the system stop offering to keep an old snapshot alive (storage cap? per-tenant cap on number of concurrent snapshots? hard expiry?); the goal is to avoid unbounded accumulation while keeping tenant control | Insight Product Team + Backend tech lead | DESIGN |
| Native Insight Connector Protocol — if and when we define a protocol beyond Airbyte wrapping; stdin/stdout JSONL vs gRPC vs OpenAPI endpoints; is the protocol necessary in v1 or is "container writes to its declared scope" enough | Ingestion tech lead | DESIGN / ADR, post-v1 if possible |
| Per-tenant isolation mechanism within a single snapshot — schema-per-install (snapshot+install in the schema name) appears to be the right model given the snapshot architecture, but the choice between `tenant_id` column + RLS vs schema-per-install for any tables that span installs (e.g., system audit) needs DESIGN | Data tech lead | DESIGN |
| Installed-inventory data model — exact tables for `tenant_snapshot`, `snapshot_plugin_install`, `snapshot_status`, audit log shape, the live-pointer transactional semantics during promote | Backend tech lead | DESIGN |
| Integration testing strategy — how does a plugin author test their plugin against a real customer data shape when the customer's source system is behind a firewall Insight cannot reach; options include recorded/anonymized request traces shipped to the author, an opt-in customer-side trace-collection service operated by the Insight team, mock servers per connector type, or a combination | Plugin Author lead + Customer Success | DESIGN + customer-engagement policy; track separately from the data-model DESIGN |
| Plugin-authoring SDK / CLI — `insight-plugin init` / `validate` / `test` / `package` / `publish` (pipe-escaped to avoid table-render issues) — is it v1 ("can't ship without this") or v2 ("docs + reference plugins first, CLI when patterns stabilize"); the intent is the latter, but the threshold at which the CLI becomes a necessity should be articulated | Plugin Author lead | v2 planning; revisit after first three external plugins |
| Widget data-contract expressiveness — is "table schema with columns + config JSON schema" sufficient for the interesting widget cases, or does it need streaming, multi-query, or cross-entity access; depends on dashboard-configurator direction | Frontend tech lead | DESIGN, after first 3 widget plugins |
| Signing-key management — exact HSM / Vault choice for vendor signing key, key rotation cadence and procedure, instance-admin trust-root registration UX, revocation list distribution to air-gapped customers | Security lead | DESIGN, before vendor-signed plugins are first published |
| Image scanning policy — which scanner (Trivy, Grype, Syft + custom rules), CVE severity threshold for hard-block vs warn, how to handle scanner-FN cases | Security lead | DESIGN |
| Egress proxy implementation — declarative `NetworkPolicy` is enough for L4 allowlist, but L7 (e.g., HTTP host-based) needs an explicit proxy (Squid, Envoy with allowlist, or sidecar); pick one for v1 | Platform / SRE | DESIGN |
| Catalog governance — given that snapshots are tenant-authored and vendor reference snapshots are optional, what does the catalog actually publish? Just plugin metadata, or also reference snapshots? Who approves a third-party plugin's inclusion, what compatibility tests run, how unmaintained plugins are retired | Insight Product Team | Policy doc, before third-party publish path opens |
| Cross-tenant plugin sharing — an instance admin shipping a snapshot template across all tenants in one step (for a customer with many tenants in one instance); whether this is a v1 convenience or belongs in v2 | Insight Product Team | v2 planning |
| Plugin health → end-user surface — what exactly does "data temporarily unavailable" look like; is it per-widget or per-dashboard; does it communicate "connector X failed" vs "silver transform failed" to the user or only to the admin | Product design + Frontend | Coordinated design pass before first external plugin ships |
| Transition off Airbyte — at what point does the connector capability stop needing Airbyte source protocol support (when all connector plugins are native) and is removing that support a major-version bump of the plugin system | Ingestion tech lead | Roadmap item after native protocol stabilizes |

---
status: proposed
date: 2026-04-01
---

# ADR-0003: Use Kubernetes Secrets as the Primary Credential Source for Connectors

**ID**: `cpt-insightspec-adr-k8s-secrets-credentials`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [K8s Secrets with label-based discovery](#k8s-secrets-with-label-based-discovery)
  - [HashiCorp Vault direct integration](#hashicorp-vault-direct-integration)
  - [SOPS-encrypted YAML](#sops-encrypted-yaml)
  - [Environment variables](#environment-variables)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

Constructor Insight is an open-source project. Consumers deploy it into their own Kubernetes clusters and need to control connector credentials (API keys, OAuth client secrets, tokens) through their existing secret management infrastructure — whether that is HashiCorp Vault with External Secrets Operator, Bitnami Sealed Secrets, or manual `kubectl create secret`.

Currently, credentials are stored as plaintext values inline in tenant configuration YAML files (`connections/{tenant}.yaml`) and passed directly to the Airbyte API by `apply-connections.sh`. This approach has several problems:

- Plaintext secrets in config files are a security risk, especially when configs are stored in Git or GitOps manifests.
- Consumers cannot use their standard K8s-native secret management tooling.
- Local development uses a different credential flow than production, violating dev/prod parity.

The ingestion layer needs a credential resolution mechanism that is secure by default, works uniformly across local development and production environments, and does not couple Insight to any specific vault technology.

## Decision Drivers

* Consumers must manage credentials through their own infrastructure without modifying Insight source code
* Plaintext credentials in YAML configuration files are a security risk
* Kubernetes Secrets are the standard secret primitive in all target deployment environments (production clusters and local kind/minikube)
* Local development environments should mirror production credential flow (dev/prod parity)
* The solution must maintain backward compatibility during the transition period
* Minimal changes to the existing `apply-connections.sh` pipeline

## Considered Options

* **K8s Secrets with label-based discovery** — `apply-connections.sh` discovers Secrets by label `app.kubernetes.io/part-of=insight` and reads connector type from annotation `insight.cyberfabric.com/connector`
* **HashiCorp Vault direct integration** — `apply-connections.sh` calls the Vault HTTP API directly to fetch secrets
* **SOPS-encrypted YAML** — credentials remain inline but encrypted using Mozilla SOPS; decrypted at apply time
* **Environment variables** — credentials injected as environment variables by the Kubernetes pod spec (from Secrets or ConfigMaps)

## Decision Outcome

Chosen option: **K8s Secrets with label-based discovery**, because Kubernetes Secrets are the lowest-common-denominator abstraction for secret storage in K8s environments. Regardless of how consumers provision secrets — Vault + ESO, Sealed Secrets, or manual creation — all approaches materialize as native K8s Secret objects. The script discovers Secrets by label `app.kubernetes.io/part-of=insight` and reads the connector type from annotation `insight.cyberfabric.com/connector`, eliminating the need for any Secret references in tenant config YAML. This provides zero coupling to any specific vault technology while enabling a uniform credential flow for both production and local development (kind/minikube with the same Secret objects).

### Consequences

* Good, because consumers control the full lifecycle of their secrets without modifying Insight code or configuration templates
* Good, because the solution works with any secret provisioning tool that produces K8s Secrets
* Good, because local development uses the same label-based discovery as production (kind cluster with locally-created Secrets)
* Good, because the credential model is simple and unambiguous — K8s Secrets are the sole source, no fallback logic to debug
* Bad, because the pod running `apply-connections.sh` requires `kubectl` access and a ServiceAccount with RBAC permissions to read Secrets in the target namespace
* Bad, because Secret field names must exactly match the connector's `connection_specification` — consumers need per-connector documentation of required fields
* Note: inline credentials have been fully removed — K8s Secrets are the sole source with no fallback

### Confirmation

Confirmed when:

- `apply-connections.sh` discovers K8s Secrets by label and successfully creates Airbyte sources from Secret data
- A local kind cluster setup guide demonstrates creating Secrets and running the pipeline end-to-end
- Connectors without a matching K8s Secret are skipped with a clear error message
- Per-connector Secret field documentation is published

## Pros and Cons of the Options

### K8s Secrets with label-based discovery

The apply script discovers Secrets by label `app.kubernetes.io/part-of=insight` in the current namespace. Connector type is read from annotation `insight.cyberfabric.com/connector` (must match `descriptor.yaml` `name` field). Source instance ID is read from annotation `insight.cyberfabric.com/source-id` and injected as `insight_source_id`. Naming convention `insight-{connector}-{source_id}` is recommended for human readability but not required — discovery uses labels/annotations, not Secret names.

Multiple Secrets with the same connector annotation create multiple Airbyte source instances (multi-instance: multiple Bitbucket servers, multiple M365 tenants). Non-credential config (e.g., `start_date`) remains in tenant YAML and is merged with Secret data (inline takes precedence).

* Good, because it is the lowest-common-denominator abstraction — all K8s secret management tools produce K8s Secrets
* Good, because there is zero coupling to a specific vault vendor
* Good, because label-based discovery requires no Secret references in tenant config
* Good, because inline field override allows non-sensitive config in tenant YAML (e.g., `start_date`)
* Good, because multi-instance is automatic — each Secret becomes a separate Airbyte source
* Neutral, because it requires RBAC configuration for the apply script's ServiceAccount
* Bad, because it adds a runtime dependency on `kubectl` availability inside the pod

### HashiCorp Vault direct integration

The apply script calls the Vault HTTP API to fetch secrets, using a Vault token or Kubernetes auth method.

* Good, because Vault provides advanced features (dynamic secrets, lease management, audit logging)
* Bad, because it tightly couples the script to Vault — consumers using other secret managers would need adapter code
* Bad, because it requires Vault client configuration (address, auth method, mount paths) in the apply script
* Bad, because it adds significant complexity for consumers who do not use Vault

### SOPS-encrypted YAML

Credentials remain inline in tenant config but encrypted using Mozilla SOPS with age, PGP, or cloud KMS keys. Decrypted at apply time.

* Good, because secrets can be committed to Git safely (encrypted at rest)
* Good, because no runtime dependency on external secret stores
* Bad, because consumers must manage encryption keys and distribute them to CI/CD and local environments
* Bad, because it does not align with K8s-native secret management practices
* Bad, because local development still requires key distribution for decryption

### Environment variables

Credentials passed as environment variables to the pod running `apply-connections.sh`, sourced from K8s Secrets or ConfigMaps via the pod spec.

* Good, because it uses standard K8s env injection — no extra tooling needed
* Bad, because environment variables have a flat namespace — no structure for multi-connector, multi-instance configurations
* Bad, because mapping N connectors × M fields to individual env vars is error-prone and hard to document
* Bad, because env vars are visible in pod specs and process listings, reducing security

## More Information

- Discovery uses label `app.kubernetes.io/part-of=insight` and annotations `insight.cyberfabric.com/connector`, `insight.cyberfabric.com/source-id`.
- Naming convention `insight-{connector}-{source_id}` is recommended for readability: `insight-m365-main`, `insight-m365-emea`, `insight-bitbucket-server-prod`, etc.
- Secret data field names are derived from each connector's `spec.connection_specification` in `connector.yaml`. Each connector's `README.md` documents required fields.
- `insight_tenant_id` is injected from tenant YAML `tenant_id`, not from the Secret.
- `insight_source_id` is injected from the Secret's `insight.cyberfabric.com/source-id` annotation, not from Secret data.
- The merge strategy (Secret fields as base, inline tenant YAML fields as override) allows non-sensitive configuration like `start_date` to remain in tenant YAML while credentials live in the Secret.
- Consumers are responsible for Secret creation and lifecycle; Insight only reads them via label discovery.

## Traceability

- **PRD**: [PRD.md](../PRD.md)
- **DESIGN**: [DESIGN.md](../DESIGN.md)

This decision directly addresses the following requirements:

* `cpt-insightspec-fr-ing-secret-management` — Provides the primary mechanism for secure credential storage via K8s Secrets, replacing plaintext inline credentials as the default approach

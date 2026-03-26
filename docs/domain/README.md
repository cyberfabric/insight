# Domain Specifications

Domain-level specifications for the Insight platform. Each domain represents a bounded context with its own PRD, DESIGN, and ADR documents.

## Domains

| Domain | Description | Status |
|---|---|---|
| [`ingestion/`](ingestion/) | Data pipeline from source APIs to Silver step 1 (Airbyte + Kestra + dbt) | Proposed |
| [`airbyte-connector/`](airbyte-connector/) | Connector development guide: nocode and CDK patterns, packaging, debugging | Proposed |
| [`identity-resolution/`](identity-resolution/) | Person identity matching and resolution across sources | Proposed |
| [`connector/`](connector/) | Connector Framework (custom runtime) — **superseded by ingestion/** | Historical |

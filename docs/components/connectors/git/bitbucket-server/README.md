# Bitbucket Server Connector

Connector for collecting version control data from self-hosted **Bitbucket Server** and **Bitbucket Data Center** instances via the REST API v1.0.

Collected data is mapped to the unified `git_*` Silver schema (see [`docs/components/connectors/git/README.md`](../README.md)) with `data_source = "insight_bitbucket_server"`.

## Documents

| File | Description |
|------|-------------|
| [`bitbucket.md`](./bitbucket.md) | Original reference document — full API, field mapping, and collection notes |
| [`specs/PRD.md`](./specs/PRD.md) | Product Requirements Document — actors, functional & non-functional requirements, use cases, acceptance criteria |
| [`specs/DESIGN.md`](./specs/DESIGN.md) | Technical Design — architecture, component model, sequence diagrams, field mappings, DB schema; intended as the basis for code generation |

## Scope

- **In scope**: Bitbucket Server / Data Center, REST API v1.0
- **Out of scope**: Bitbucket Cloud (different API, different auth)

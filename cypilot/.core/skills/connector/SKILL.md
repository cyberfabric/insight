---
name: connector
description: "Create, test, validate, and deploy Insight Connectors"
---

# Connector Skill

Manages the full lifecycle of Insight Connectors: creation, testing, schema generation, validation, and deployment.

## References

Before executing any workflow, read the connector specification:
- **DESIGN**: `docs/domain/connector/specs/DESIGN.md` — mandatory fields, manifest rules, package structure
- **README**: `src/ingestion/README.md` — commands, project structure

## Command Routing

Parse the user's command and route to the appropriate workflow:

| Command | Workflow | Description |
|---------|----------|-------------|
| `/connector create <name>` | [create.md](workflows/create.md) | Create new connector package |
| `/connector test <name>` | [test.md](workflows/test.md) | Test connector (check, discover, read) |
| `/connector schema <name>` | [schema.md](workflows/schema.md) | Generate JSON schema from real data |
| `/connector validate <name>` | [validate.md](workflows/validate.md) | Validate package against spec |
| `/connector deploy <name>` | [deploy.md](workflows/deploy.md) | Deploy to Airbyte + Argo |
| `/connector workflow <name>` | [workflow.md](workflows/workflow.md) | Create/customize Argo workflow templates |

### Argument Parsing

```
/connector <command> <name> [options]

<name>     Connector name (e.g. m365, bamboohr, jira)
           Or full path: collaboration/m365, hr-directory/bamboohr
```

If `<name>` is not a path, search `src/ingestion/connectors/` for it.

If `<command>` is omitted, show available commands and existing connectors.

### Context Variables

Set these before routing to workflow:

| Variable | Source | Example |
|----------|--------|---------|
| `CONNECTOR_NAME` | from argument | `m365` |
| `CONNECTOR_PATH` | resolved | `collaboration/m365` |
| `CONNECTOR_DIR` | full path | `src/ingestion/connectors/collaboration/m365` |
| `CONNECTOR_TYPE` | from descriptor.yaml or user input | `nocode` or `cdk` |
| `INGESTION_DIR` | fixed | `src/ingestion` |

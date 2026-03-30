---
name: connector-validate
description: "Validate an Insight Connector package against spec"
---

# Validate Connector

Checks that a connector package meets all requirements from the connector spec.

## Checklist

Read connector package files and verify each item:

### Structure
- [ ] `connector.yaml` exists (nocode) or `src/source_<name>/source.py` exists (CDK)
- [ ] `descriptor.yaml` exists with required fields (name, version, type, schedule, dbt_select, connection)
- [ ] `credentials.yaml.example` exists with `insight_source_id`
- [ ] `dbt/` directory with at least one .sql model and schema.yml

### Manifest (nocode)
- [ ] `version: 7.0.4` or compatible
- [ ] `type: DeclarativeSource`
- [ ] `spec.connection_specification` has `insight_tenant_id` as required
- [ ] `spec.connection_specification` has `insight_source_id` as required
- [ ] All config fields use prefixes (insight_*, azure_*, github_*, etc.)
- [ ] No bare `tenant_id` or `client_id` in config fields
- [ ] AddFields includes `tenant_id` from `config['insight_tenant_id']`
- [ ] AddFields includes `source_id` from `config['insight_source_id']`
- [ ] AddFields includes `unique_key` with pattern: `{tenant_id}-{source_id}-{natural_key}`
- [ ] InlineSchemaLoader has `additionalProperties: true`
- [ ] Schema includes `tenant_id`, `source_id`, `unique_key` as string fields
- [ ] Nullable types used only where API actually returns null (not all fields)

### CDK (Python)
- [ ] `parse_response()` injects `tenant_id`, `source_id`, `unique_key`
- [ ] `unique_key` includes `tenant_id` and `source_id`
- [ ] `spec.json` has `insight_tenant_id` and `insight_source_id` as required

### Descriptor
- [ ] `name` matches directory name
- [ ] `connection.namespace` = `bronze_<name>`
- [ ] `dbt_select` includes both connector tag and `tag:silver`
- [ ] `schedule` is valid cron expression
- [ ] `connection.streams` lists all streams from manifest

### dbt Models
- [ ] Model name follows `<connector>__<domain>.sql` pattern
- [ ] `materialized='incremental'`
- [ ] `schema='staging'`
- [ ] Tags include connector name and `silver:class_<domain>`
- [ ] SELECT includes `tenant_id`, `source_id`, `unique_key`
- [ ] Uses `{{ source('bronze_<name>', '<stream>') }}`
- [ ] Has `{% if is_incremental() %}` block

### dbt schema.yml
- [ ] Source defined with `schema: bronze_<name>`
- [ ] Model has `tenant_id` with not_null test
- [ ] Model has `source_id` with not_null test
- [ ] Model has `unique_key` with not_null and unique tests

### Credentials Template
- [ ] `credentials.yaml.example` lists all required fields
- [ ] `insight_source_id` is included
- [ ] No real credentials in any tracked file

## Output

```
=== Connector Validation: <name> ===

  Structure:    PASS (4/4)
  Manifest:     PASS (12/12)  or  CDK: PASS (3/3)
  Descriptor:   PASS (5/5)
  dbt Models:   PASS (7/7)
  dbt Schema:   PASS (4/4)
  Credentials:  PASS (3/3)

  Status: PASS
```

If any FAIL, show specific issue with file:line and fix suggestion.

---
name: connector-test
description: "Test an Insight Connector: check, discover, read"
---

# Test Connector

Runs the full test cycle for a connector.

## Prerequisites

- Connector package exists at `CONNECTOR_DIR`
- Tenant credentials configured in `connections/<tenant>.yaml`

## Phase 1: Resolve Tenant

If tenant not specified, auto-detect from connections/*.yaml:
```bash
# Find first tenant with credentials for this connector
ls src/ingestion/connections/*.yaml
```

## Phase 2: Validate Manifest

```bash
./tools/declarative-connector/source.sh validate CONNECTOR_PATH
```

Expected: `Manifest is valid`
If fails: show error, suggest fix, STOP.

## Phase 3: Check Credentials

```bash
./tools/declarative-connector/source.sh check CONNECTOR_PATH <tenant>
```

Expected: `CONNECTION_STATUS: SUCCEEDED`
If fails: check credentials in tenant yaml, show error.

## Phase 4: Discover Streams

```bash
./tools/declarative-connector/source.sh discover CONNECTOR_PATH <tenant>
```

Parse output and show:
```
Discovered N streams:
  stream_name_1: M fields
  stream_name_2: M fields
```

## Phase 5: Read Data

```bash
# Generate catalog if missing
./scripts/generate-catalog.sh CONNECTOR_NAME <tenant>

# Read data
./tools/declarative-connector/source.sh read CONNECTOR_PATH <tenant>
```

Parse output and verify:
- [ ] Every RECORD has `tenant_id` field (not null, not empty)
- [ ] Every RECORD has `source_id` field (not null, not empty)
- [ ] Every RECORD has `unique_key` field (not null, not empty)
- [ ] `unique_key` contains `tenant_id` and `source_id`
- [ ] Expected streams are present in output
- [ ] Records have expected fields from API

Show sample:
```
Stream: email_activity (N records)
  Sample: tenant_id=example_tenant, source_id=m365-main, unique_key=example_tenant-m365-main-...
  Fields: tenant_id, source_id, unique_key, userPrincipalName, sendCount, ...
```

## Phase 6: Verify Schema Completeness

After discover, verify that ALL cursor fields exist in the schema:
- For each stream with `incremental_sync`, check that `cursor_field` is in the stream's `json_schema.properties`
- If missing: the field is from raw API response but not in inline schema → add it to schema and re-test

```bash
# Generate schema from real data
./scripts/generate-schema.sh <name> <tenant>

# Compare generated schema with inline schema in manifest
# Every field in generated schema should be in manifest inline schema
# Especially cursor fields (e.g. end_time for meetings)
```

This prevents ClickHouse destination NPE on deploy.

## Phase 7: Summary

```
=== Test Results ===
  Validate:  PASS
  Check:     PASS
  Discover:  PASS (N streams)
  Read:      PASS (N records)
  tenant_id: PASS (present in all records)
  source_id: PASS (present in all records)
  unique_key: PASS (contains tenant_id + source_id)
  Schema:    PASS (all cursor fields present)

Next: /connector deploy <name>
```

---
name: connector-deploy
description: "Deploy connector to Airbyte + Argo"
---

# Deploy Connector

Registers connector in Airbyte, creates connections, and sets up Argo workflows.

## Prerequisites

- Connector package validated (`/connector validate <name>` passed)
- Tenant credentials in `connections/<tenant>.yaml`
- Cluster running (`./up.sh` completed)

## Phase 1: Upload Manifest

```bash
./update-connectors.sh
```

Registers/updates connector definition in Airbyte.

## Phase 2: Create Connections

```bash
./update-connections.sh <tenant>
```

Creates:
- ClickHouse destination (`bronze_<name>` database)
- Source with tenant credentials
- Connection with discovered catalog (all streams enabled)

## Phase 3: Create Workflows

```bash
./update-workflows.sh <tenant>
```

Generates CronWorkflow from `descriptor.yaml` schedule.

## Phase 4: Verify

```bash
# Check in Airbyte
# Source exists and test passes
# Destination exists and test passes
# Connection exists with correct streams

# Check in Argo
kubectl get cronworkflows -n argo
```

## Phase 5: Run First Sync

Ask user: "Run first sync now? [y/n]"

If yes:
```bash
./run-sync.sh <name> <tenant>
```

Monitor with:
```bash
./logs.sh -f latest
```

## Phase 6: Verify Data

After sync completes:
```sql
-- Bronze
SELECT count(*) FROM bronze_<name>.<stream>;

-- Staging (after dbt)
SELECT count(*) FROM staging.<name>__<domain>;

-- Silver (after dbt)
SELECT count(*) FROM silver.class_<domain>;
```

## Summary

```
=== Deployment: <name> ===

  Connector:  registered in Airbyte
  Destination: bronze_<name> (ClickHouse)
  Connection: <name>-to-clickhouse-<tenant> (N streams)
  Workflow:   <name>-sync (schedule: 0 2 * * *)
  First sync: PASS (N rows in bronze, M in staging, M in silver)
```

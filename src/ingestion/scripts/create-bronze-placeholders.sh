#!/usr/bin/env bash
# Create empty placeholder bronze tables for connectors that are referenced by
# gold-views migration but have no credentials yet (no secret file).
#
# This lets the gold-views migration succeed in partial deployments where not
# all connectors are configured. When a connector is later configured and
# Airbyte runs its first sync, Airbyte will drop the placeholder and create
# a real table with its own schema.
#
# Connectors referenced by gold-views: jira, m365, zoom, bamboohr.
# bamboohr has no placeholder — it's the primary people source and must have
# real data for gold views to be meaningful.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INGESTION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$INGESTION_DIR/secrets/connectors"

CH_PASS="${CLICKHOUSE_PASSWORD:-$(kubectl get secret clickhouse-credentials -n data -o jsonpath='{.data.password}' | base64 -d)}"

run_ch() {
  kubectl exec -i -n data deploy/clickhouse -- env CLICKHOUSE_PASSWORD="$CH_PASS" clickhouse-client --multiquery
}

ch_table_exists() {
  local db="$1" tbl="$2"
  local result
  result=$(kubectl exec -n data deploy/clickhouse -- env CLICKHOUSE_PASSWORD="$CH_PASS" clickhouse-client -q \
    "SELECT count() FROM system.tables WHERE database='$db' AND name='$tbl'" 2>/dev/null || echo "0")
  [[ "$result" == "1" ]]
}

secret_exists() {
  [[ -f "$SECRETS_DIR/$1.yaml" ]]
}

echo "=== Bronze placeholders (for missing connectors) ==="

# silver.class_comms_events — dbt-generated view, placeholder for gold-views dep
if ! ch_table_exists silver class_comms_events; then
  echo "  Creating placeholder: silver.class_comms_events"
  run_ch <<'SQL'
CREATE DATABASE IF NOT EXISTS silver;
CREATE TABLE IF NOT EXISTS silver.class_comms_events (
    user_email String,
    activity_date Date,
    emails_sent Float64,
    source String
) ENGINE = MergeTree ORDER BY (user_email, activity_date);
SQL
fi

# bronze_jira — needed by gold-views jira_person_daily, jira_closed_tasks
if ! secret_exists jira && ! ch_table_exists bronze_jira jira_issue; then
  echo "  Creating placeholder: bronze_jira.jira_issue (no jira secret)"
  run_ch <<'SQL'
CREATE DATABASE IF NOT EXISTS bronze_jira;
CREATE TABLE IF NOT EXISTS bronze_jira.jira_issue (
    id String,
    id_readable String,
    issue_type String,
    updated String,
    due_date String,
    custom_fields_json String,
    _airbyte_extracted_at DateTime64(3, 'UTC') DEFAULT now64(3)
) ENGINE = MergeTree ORDER BY id;
SQL
fi

# bronze_m365 — needed by gold-views teams_person_daily, files_person_daily, comms_daily
if ! secret_exists m365; then
  if ! ch_table_exists bronze_m365 teams_activity; then
    echo "  Creating placeholder: bronze_m365.teams_activity (no m365 secret)"
    run_ch <<'SQL'
CREATE DATABASE IF NOT EXISTS bronze_m365;
CREATE TABLE IF NOT EXISTS bronze_m365.teams_activity (
    userPrincipalName String,
    lastActivityDate String,
    teamChatMessageCount Nullable(Float64),
    privateChatMessageCount Nullable(Float64),
    meetingsAttendedCount Nullable(Float64),
    callCount Nullable(Float64),
    _airbyte_extracted_at DateTime64(3, 'UTC') DEFAULT now64(3)
) ENGINE = MergeTree ORDER BY userPrincipalName;
CREATE TABLE IF NOT EXISTS bronze_m365.onedrive_activity (
    userPrincipalName String,
    lastActivityDate String,
    sharedInternallyFileCount Nullable(Float64),
    sharedExternallyFileCount Nullable(Float64),
    _airbyte_extracted_at DateTime64(3, 'UTC') DEFAULT now64(3)
) ENGINE = MergeTree ORDER BY userPrincipalName;
CREATE TABLE IF NOT EXISTS bronze_m365.sharepoint_activity (
    userPrincipalName String,
    lastActivityDate String,
    sharedInternallyFileCount Nullable(Float64),
    sharedExternallyFileCount Nullable(Float64),
    _airbyte_extracted_at DateTime64(3, 'UTC') DEFAULT now64(3)
) ENGINE = MergeTree ORDER BY userPrincipalName;
SQL
  fi
fi

# bronze_zoom — needed by gold-views comms_daily, zoom_person_daily
if ! secret_exists zoom && ! ch_table_exists bronze_zoom participants; then
  echo "  Creating placeholder: bronze_zoom.participants (no zoom secret)"
  run_ch <<'SQL'
CREATE DATABASE IF NOT EXISTS bronze_zoom;
CREATE TABLE IF NOT EXISTS bronze_zoom.participants (
    email String,
    meeting_uuid String,
    join_time String,
    leave_time String,
    _airbyte_extracted_at DateTime64(3, 'UTC') DEFAULT now64(3)
) ENGINE = MergeTree ORDER BY email;
SQL
fi

echo "=== Placeholders: done ==="

//! Slack metrics update — rename mislabeled keys + add consistency metrics
//! in the TEAM_BULLET_COLLAB (UUID …05) and IC_BULLET_COLLAB (UUID …12)
//! bullet aggregation queries.
//!
//! Renames:
//!   slack_message_engagement   → slack_messages_sent
//!   slack_thread_participation → slack_channel_posts
//!
//! New metrics added to the inner-aggregation `sum`-list:
//!   slack_active_days          (per-day 1/0 → period total = active days)
//!
//! New metric using default `avg`-aggregation (emitted as NULL on inactive
//! days so CH avg() yields mean intensity over active days):
//!   slack_msgs_per_active_day
//!
//! Paired with CH migration `20260428000000_slack-metrics-update.sql` which
//! redefines `insight.collab_bullet_rows` to emit the renamed keys and the
//! two new metrics.

use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const TEAM_BULLET_COLLAB_ID: &str = "00000000000000000001000000000005";
const IC_BULLET_COLLAB_ID: &str = "00000000000000000001000000000012";

const TEAM_BULLET_COLLAB_QUERY: &str = "SELECT p.metric_key AS metric_key, avg(p.v_period) AS value, any(c.company_median) AS median, any(c.company_min) AS range_min, any(c.company_max) AS range_max FROM (SELECT metric_key, person_id, any(org_unit_id) AS org_unit_id, multiIf(metric_key IN ('m365_emails_sent', 'zoom_calls', 'meeting_hours', 'm365_teams_messages', 'm365_files_shared', 'meeting_free', 'slack_channel_posts', 'slack_messages_sent', 'slack_active_days'), sum(metric_value), avg(metric_value)) AS v_period FROM insight.collab_bullet_rows GROUP BY metric_key, person_id) p LEFT JOIN (SELECT metric_key, quantileExact(0.5)(v_period) AS company_median, min(v_period) AS company_min, max(v_period) AS company_max FROM (SELECT metric_key, person_id, multiIf(metric_key IN ('m365_emails_sent', 'zoom_calls', 'meeting_hours', 'm365_teams_messages', 'm365_files_shared', 'meeting_free', 'slack_channel_posts', 'slack_messages_sent', 'slack_active_days'), sum(metric_value), avg(metric_value)) AS v_period FROM insight.collab_bullet_rows GROUP BY metric_key, person_id) inner_c GROUP BY metric_key) c ON c.metric_key = p.metric_key GROUP BY p.metric_key";

const IC_BULLET_COLLAB_QUERY: &str = "SELECT p.metric_key AS metric_key, avg(p.v_period) AS value, any(c.team_median) AS median, any(c.team_min) AS range_min, any(c.team_max) AS range_max FROM (SELECT metric_key, person_id, any(org_unit_id) AS org_unit_id, multiIf(metric_key IN ('m365_emails_sent', 'zoom_calls', 'meeting_hours', 'm365_teams_messages', 'm365_files_shared', 'meeting_free', 'slack_channel_posts', 'slack_messages_sent', 'slack_active_days'), sum(metric_value), avg(metric_value)) AS v_period FROM insight.collab_bullet_rows GROUP BY metric_key, person_id) p LEFT JOIN (SELECT metric_key, org_unit_id, quantileExact(0.5)(v_period) AS team_median, min(v_period) AS team_min, max(v_period) AS team_max FROM (SELECT metric_key, person_id, any(org_unit_id) AS org_unit_id, multiIf(metric_key IN ('m365_emails_sent', 'zoom_calls', 'meeting_hours', 'm365_teams_messages', 'm365_files_shared', 'meeting_free', 'slack_channel_posts', 'slack_messages_sent', 'slack_active_days'), sum(metric_value), avg(metric_value)) AS v_period FROM insight.collab_bullet_rows GROUP BY metric_key, person_id) inner_c GROUP BY metric_key, org_unit_id) c ON c.metric_key = p.metric_key AND c.org_unit_id = p.org_unit_id GROUP BY p.metric_key";

// Snapshotted from m20260422_000001_seed_metrics so `down()` can restore
// the exact pre-rename text on rollback.
const TEAM_BULLET_COLLAB_QUERY_OLD: &str = "SELECT p.metric_key AS metric_key, avg(p.v_period) AS value, any(c.company_median) AS median, any(c.company_min) AS range_min, any(c.company_max) AS range_max FROM (SELECT metric_key, person_id, any(org_unit_id) AS org_unit_id, multiIf(metric_key IN ('m365_emails_sent', 'zoom_calls', 'meeting_hours', 'm365_teams_messages', 'm365_files_shared', 'meeting_free', 'slack_thread_participation', 'slack_message_engagement'), sum(metric_value), avg(metric_value)) AS v_period FROM insight.collab_bullet_rows GROUP BY metric_key, person_id) p LEFT JOIN (SELECT metric_key, quantileExact(0.5)(v_period) AS company_median, min(v_period) AS company_min, max(v_period) AS company_max FROM (SELECT metric_key, person_id, multiIf(metric_key IN ('m365_emails_sent', 'zoom_calls', 'meeting_hours', 'm365_teams_messages', 'm365_files_shared', 'meeting_free', 'slack_thread_participation', 'slack_message_engagement'), sum(metric_value), avg(metric_value)) AS v_period FROM insight.collab_bullet_rows GROUP BY metric_key, person_id) inner_c GROUP BY metric_key) c ON c.metric_key = p.metric_key GROUP BY p.metric_key";

const IC_BULLET_COLLAB_QUERY_OLD: &str = "SELECT p.metric_key AS metric_key, avg(p.v_period) AS value, any(c.team_median) AS median, any(c.team_min) AS range_min, any(c.team_max) AS range_max FROM (SELECT metric_key, person_id, any(org_unit_id) AS org_unit_id, multiIf(metric_key IN ('m365_emails_sent', 'zoom_calls', 'meeting_hours', 'm365_teams_messages', 'm365_files_shared', 'meeting_free', 'slack_thread_participation', 'slack_message_engagement'), sum(metric_value), avg(metric_value)) AS v_period FROM insight.collab_bullet_rows GROUP BY metric_key, person_id) p LEFT JOIN (SELECT metric_key, org_unit_id, quantileExact(0.5)(v_period) AS team_median, min(v_period) AS team_min, max(v_period) AS team_max FROM (SELECT metric_key, person_id, any(org_unit_id) AS org_unit_id, multiIf(metric_key IN ('m365_emails_sent', 'zoom_calls', 'meeting_hours', 'm365_teams_messages', 'm365_files_shared', 'meeting_free', 'slack_thread_participation', 'slack_message_engagement'), sum(metric_value), avg(metric_value)) AS v_period FROM insight.collab_bullet_rows GROUP BY metric_key, person_id) inner_c GROUP BY metric_key, org_unit_id) c ON c.metric_key = p.metric_key AND c.org_unit_id = p.org_unit_id GROUP BY p.metric_key";

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();

        for (hex_id, query) in [
            (TEAM_BULLET_COLLAB_ID, TEAM_BULLET_COLLAB_QUERY),
            (IC_BULLET_COLLAB_ID, IC_BULLET_COLLAB_QUERY),
        ] {
            db.execute_unprepared(&format!(
                "UPDATE metrics SET query_ref = '{qr}' WHERE id = UNHEX('{hex_id}')",
                qr = query.replace('\'', "''"),
            ))
            .await?;
        }

        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();

        for (hex_id, query) in [
            (TEAM_BULLET_COLLAB_ID, TEAM_BULLET_COLLAB_QUERY_OLD),
            (IC_BULLET_COLLAB_ID, IC_BULLET_COLLAB_QUERY_OLD),
        ] {
            db.execute_unprepared(&format!(
                "UPDATE metrics SET query_ref = '{qr}' WHERE id = UNHEX('{hex_id}')",
                qr = query.replace('\'', "''"),
            ))
            .await?;
        }

        Ok(())
    }
}

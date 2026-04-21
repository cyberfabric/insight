//! Seed metric definitions for all FE dashboard views.
//!
//! UUIDs match `insight-front/src/screensets/insight/api/metricRegistry.ts`.
//! Each metric's `query_ref` points to a ClickHouse view in the `insight` DB
//! created by `20260417000000_gold-views.sql`.

use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

/// Metric seed row: (hex_id, name, description, query_ref).
const SEEDS: &[(&str, &str, &str, &str)] = &[
    // EXEC_SUMMARY (00000000-0000-0000-0001-000000000001)
    (
        "00000000000000000001000000000001",
        "Executive Summary",
        "Org-unit level summary: headcount, tasks, bugs, focus, AI adoption, PR cycle time",
        "SELECT org_unit_id, org_unit_name, headcount, sum(tasks_closed) AS tasks_closed, sum(bugs_fixed) AS bugs_fixed, build_success_pct, round(avg(focus_time_pct), 1) AS focus_time_pct, ai_adoption_pct, ai_loc_share_pct, pr_cycle_time_h FROM insight.exec_summary GROUP BY org_unit_id, org_unit_name, headcount, build_success_pct, ai_adoption_pct, ai_loc_share_pct, pr_cycle_time_h",
    ),
    // TEAM_MEMBER (00000000-0000-0000-0001-000000000002)
    (
        "00000000000000000001000000000002",
        "Team Members",
        "Per-person metrics for team view: tasks, bugs, dev time, PRs, focus, AI tools",
        "SELECT person_id, display_name, seniority, org_unit_id, tasks_closed, bugs_fixed, dev_time_h, prs_merged, build_success_pct, focus_time_pct, ai_tools, ai_loc_share_pct, metric_date FROM insight.team_member",
    ),
    // TEAM_BULLET_DELIVERY (00000000-0000-0000-0001-000000000003)
    (
        "00000000000000000001000000000003",
        "Team Bullet Task Delivery",
        "Bullet chart metrics for task delivery",
        "SELECT metric_key, avg(metric_value) AS value, quantile(0.5)(metric_value) AS median, quantile(0.05)(metric_value) AS p5, quantile(0.95)(metric_value) AS p95 FROM insight.task_delivery_bullet_rows GROUP BY metric_key",
    ),
    // TEAM_BULLET_QUALITY (00000000-0000-0000-0001-000000000004)
    (
        "00000000000000000001000000000004",
        "Team Bullet Code Quality",
        "Bullet chart metrics for code quality",
        "SELECT metric_key, avg(metric_value) AS value, quantile(0.5)(metric_value) AS median, quantile(0.05)(metric_value) AS p5, quantile(0.95)(metric_value) AS p95 FROM insight.code_quality_bullet_rows GROUP BY metric_key",
    ),
    // TEAM_BULLET_COLLAB (00000000-0000-0000-0001-000000000005)
    (
        "00000000000000000001000000000005",
        "Team Bullet Collaboration",
        "Bullet chart metrics for collaboration",
        "SELECT metric_key, avg(metric_value) AS value, quantile(0.5)(metric_value) AS median, quantile(0.05)(metric_value) AS p5, quantile(0.95)(metric_value) AS p95 FROM insight.collab_bullet_rows GROUP BY metric_key",
    ),
    // TEAM_BULLET_AI (00000000-0000-0000-0001-000000000006)
    (
        "00000000000000000001000000000006",
        "Team Bullet AI Adoption",
        "Bullet chart metrics for AI adoption (placeholder)",
        "SELECT metric_key, avg(metric_value) AS value, quantile(0.5)(metric_value) AS median, quantile(0.05)(metric_value) AS p5, quantile(0.95)(metric_value) AS p95 FROM insight.ai_bullet_rows GROUP BY metric_key",
    ),
    // IC_KPIS (00000000-0000-0000-0001-000000000010)
    (
        "00000000000000000001000000000010",
        "IC KPIs",
        "Per-person KPI aggregates",
        "SELECT person_id, loc, ai_loc_share_pct, prs_merged, pr_cycle_time_h, focus_time_pct, tasks_closed, bugs_fixed, build_success_pct, ai_sessions, metric_date FROM insight.ic_kpis",
    ),
    // IC_BULLET_DELIVERY (00000000-0000-0000-0001-000000000011)
    (
        "00000000000000000001000000000011",
        "IC Bullet Task Delivery",
        "IC-level bullet metrics for task delivery",
        "SELECT metric_key, avg(metric_value) AS value, quantile(0.5)(metric_value) AS median, quantile(0.05)(metric_value) AS p5, quantile(0.95)(metric_value) AS p95 FROM insight.task_delivery_bullet_rows GROUP BY metric_key",
    ),
    // IC_BULLET_COLLAB (00000000-0000-0000-0001-000000000012)
    (
        "00000000000000000001000000000012",
        "IC Bullet Collaboration",
        "IC-level bullet metrics for collaboration",
        "SELECT metric_key, avg(metric_value) AS value, quantile(0.5)(metric_value) AS median, quantile(0.05)(metric_value) AS p5, quantile(0.95)(metric_value) AS p95 FROM insight.collab_bullet_rows GROUP BY metric_key",
    ),
    // IC_BULLET_AI (00000000-0000-0000-0001-000000000013)
    (
        "00000000000000000001000000000013",
        "IC Bullet AI",
        "IC-level bullet metrics for AI adoption (placeholder)",
        "SELECT metric_key, avg(metric_value) AS value, quantile(0.5)(metric_value) AS median, quantile(0.05)(metric_value) AS p5, quantile(0.95)(metric_value) AS p95 FROM insight.ai_bullet_rows GROUP BY metric_key",
    ),
    // IC_CHART_LOC (00000000-0000-0000-0001-000000000014)
    (
        "00000000000000000001000000000014",
        "IC Chart LOC Trend",
        "Weekly LOC trend: AI-generated, manual code, spec lines",
        "SELECT date_bucket, ai_loc, code_loc, spec_lines, person_id, metric_date FROM insight.ic_chart_loc",
    ),
    // IC_CHART_DELIVERY (00000000-0000-0000-0001-000000000015)
    (
        "00000000000000000001000000000015",
        "IC Chart Delivery Trend",
        "Weekly delivery trend: commits, PRs merged, tasks done",
        "SELECT date_bucket, commits, prs_merged, tasks_done, person_id, metric_date FROM insight.ic_chart_delivery",
    ),
    // IC_DRILL (00000000-0000-0000-0001-000000000016)
    (
        "00000000000000000001000000000016",
        "IC Drill Detail",
        "Drill-down detail for IC metrics (placeholder)",
        "SELECT person_id, drill_id, title, source, src_class, value, filter, columns, rows, metric_date FROM insight.ic_drill",
    ),
    // IC_TIMEOFF (00000000-0000-0000-0001-000000000017)
    (
        "00000000000000000001000000000017",
        "IC Time Off",
        "Upcoming time off from BambooHR leave requests",
        "SELECT person_id, days, date_range, bamboo_hr_url, metric_date FROM insight.ic_timeoff",
    ),
];

const ZERO_TENANT: &str = "00000000000000000000000000000000";

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();

        for (hex_id, name, description, query_ref) in SEEDS {
            db.execute_unprepared(&format!(
                "INSERT INTO metrics (id, insight_tenant_id, name, description, query_ref, is_enabled) \
                 VALUES (UNHEX('{hex_id}'), UNHEX('{ZERO_TENANT}'), '{name}', '{description}', '{qr}', 1) \
                 ON DUPLICATE KEY UPDATE name=VALUES(name), description=VALUES(description), query_ref=VALUES(query_ref)",
                qr = query_ref.replace('\'', "''"),
            ))
            .await?;
        }

        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();

        for (hex_id, _, _, _) in SEEDS {
            db.execute_unprepared(&format!(
                "DELETE FROM metrics WHERE id = UNHEX('{hex_id}')"
            ))
            .await?;
        }

        Ok(())
    }
}

//! Seed the IC Bullet Git metric row.
//!
//! UUID `...18` — maps to `insight-front/src/screensets/insight/api/metricRegistry.ts`
//! (`IC_BULLET_GIT`). The query uses the two-level aggregation pattern
//! documented in `m20260417_000001_seed_metrics`: inner subquery sums
//! `metric_value` per (metric_key, person_id) with the analytics-api injecting
//! the OData `metric_date` filter into the inner FROM, outer aggregates across
//! people to produce value / median / range.
//!
//! Reads from `insight.git_bullet_rows` (added in CH migration
//! `20260421000000_add-git-commits-views.sql`) which sources commits from
//! `bronze_bitbucket_cloud.commits` via `insight.commits_daily`.

use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const SEEDS: &[(&str, &str, &str, &str)] = &[
    (
        "00000000000000000001000000000018",
        "IC Bullet Git",
        "IC-level bullet metrics for git output (commits). value=person, range=team min/max",
        "SELECT p.metric_key AS metric_key, avg(p.v_period) AS value, any(c.team_median) AS median, any(c.team_min) AS range_min, any(c.team_max) AS range_max FROM (SELECT metric_key, person_id, any(org_unit_id) AS org_unit_id, sum(metric_value) AS v_period FROM insight.git_bullet_rows GROUP BY metric_key, person_id) p LEFT JOIN (SELECT metric_key, org_unit_id, quantileExact(0.5)(v_period) AS team_median, min(v_period) AS team_min, max(v_period) AS team_max FROM (SELECT metric_key, person_id, any(org_unit_id) AS org_unit_id, sum(metric_value) AS v_period FROM insight.git_bullet_rows GROUP BY metric_key, person_id) inner_c GROUP BY metric_key, org_unit_id) c ON c.metric_key = p.metric_key AND c.org_unit_id = p.org_unit_id GROUP BY p.metric_key",
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

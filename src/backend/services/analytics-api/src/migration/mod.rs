//! Database migrations for the Analytics API service.

mod m20260414_000001_init;
mod m20260417_000001_seed_metrics;
mod m20260421_000001_seed_git_metric;

use sea_orm_migration::prelude::*;

pub struct Migrator;

#[async_trait::async_trait]
impl MigratorTrait for Migrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![
            Box::new(m20260414_000001_init::Migration),
            Box::new(m20260417_000001_seed_metrics::Migration),
            Box::new(m20260421_000001_seed_git_metric::Migration),
        ]
    }
}

//! `MariaDB` connection and migration runner.

use sea_orm::{ConnectOptions, Database, DatabaseConnection};

/// Connect to `MariaDB`.
///
/// # Errors
/// Returns an error if the database URL is invalid or the connection cannot be established.
pub async fn connect(database_url: &str) -> anyhow::Result<DatabaseConnection> {
    let mut opts = ConnectOptions::new(database_url);
    opts.max_connections(10)
        .min_connections(2)
        .sqlx_logging(false);

    let db = Database::connect(opts).await?;
    tracing::info!("connected to database");
    Ok(db)
}

/// Run pending migrations.
///
/// # Errors
/// Returns an error if any migration fails to apply.
pub async fn run_migrations(db: &DatabaseConnection) -> anyhow::Result<()> {
    use sea_orm_migration::MigratorTrait;
    crate::migration::Migrator::up(db, None).await?;
    tracing::info!("migrations applied");
    Ok(())
}

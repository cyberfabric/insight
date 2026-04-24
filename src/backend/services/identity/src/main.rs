//! Identity Resolution stub — entry point.

use clap::Parser;
use tracing_subscriber::EnvFilter;

use identity_resolution::{PeopleStore, build_router, config};

#[derive(Parser)]
#[command(name = "identity-resolution")]
#[command(about = "Identity Resolution stub — person lookup from BambooHR")]
struct Cli {
    #[arg(short, long)]
    config: Option<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .json()
        .init();

    let cli = Cli::parse();
    let cfg = config::AppConfig::load(cli.config.as_deref())?;

    tracing::info!("starting identity-resolution stub");

    let mut ch_config =
        insight_clickhouse::Config::new(&cfg.clickhouse_url, &cfg.clickhouse_database);
    if let (Some(user), Some(password)) = (&cfg.clickhouse_user, &cfg.clickhouse_password) {
        ch_config = ch_config.with_auth(user, password);
    }
    let ch = insight_clickhouse::Client::new(ch_config);

    let store = PeopleStore::load(&ch).await?;
    tracing::info!(count = store.len(), "people loaded into memory");

    let app = build_router(store);

    let addr = cfg.bind_addr.parse::<std::net::SocketAddr>()?;
    tracing::info!(addr = %addr, "listening");
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

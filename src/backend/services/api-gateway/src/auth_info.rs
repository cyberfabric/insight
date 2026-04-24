//! Auth info module — public endpoint that serves OIDC configuration to the frontend.
//!
//! `GET /v1/auth/config` — no authentication required.
//!
//! Returns the OIDC provider details the frontend needs to initiate the
//! Authorization Code flow with PKCE (redirect to login page, token exchange).

use std::sync::{Arc, OnceLock};

use async_trait::async_trait;
use axum::http::{Method, StatusCode};
use axum::{Json, Router};
use modkit::api::{OpenApiRegistry, OperationBuilder};
use modkit::context::ModuleCtx;
use modkit::contracts::{Module, RestApiCapability};
use serde::{Deserialize, Serialize};

/// OIDC configuration served to the frontend.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthInfoResponse {
    /// OIDC issuer URL (e.g., `https://dev-12345.okta.com/oauth2/default`).
    pub issuer_url: String,
    /// OIDC client ID for the frontend application.
    pub client_id: String,
    /// Redirect URI after login (frontend callback URL).
    pub redirect_uri: String,
    /// Scopes to request from the OIDC provider.
    pub scopes: Vec<String>,
    /// OIDC response type (always "code" for Authorization Code flow).
    pub response_type: String,
}

/// Module configuration (from YAML).
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AuthInfoConfig {
    /// OIDC issuer URL. Should match the OIDC plugin's `issuer_url`.
    pub issuer_url: String,
    /// OIDC client ID for the frontend (public client, no secret).
    pub client_id: String,
    /// Frontend callback URL after OIDC login.
    pub redirect_uri: String,
    /// Scopes to request.
    pub scopes: Vec<String>,
}

impl Default for AuthInfoConfig {
    fn default() -> Self {
        Self {
            issuer_url: String::new(),
            client_id: String::new(),
            redirect_uri: String::new(),
            scopes: vec![
                "openid".to_owned(),
                "profile".to_owned(),
                "email".to_owned(),
            ],
        }
    }
}

/// Auth info module — serves OIDC config to the frontend.
#[modkit::module(
    name = "auth-info",
    capabilities = [rest]
)]
pub struct AuthInfoModule {
    config: OnceLock<Arc<AuthInfoConfig>>,
}

impl Default for AuthInfoModule {
    fn default() -> Self {
        Self {
            config: OnceLock::new(),
        }
    }
}

#[async_trait]
impl Module for AuthInfoModule {
    async fn init(&self, ctx: &ModuleCtx) -> anyhow::Result<()> {
        let config: AuthInfoConfig = ctx.config()?;

        if config.issuer_url.is_empty() {
            tracing::warn!(
                "auth-info: issuer_url is empty. \
                 /auth/config endpoint will return empty OIDC config. \
                 Set modules.auth-info.config.issuer_url."
            );
        }

        self.config
            .set(Arc::new(config))
            .map_err(|_| anyhow::anyhow!("auth-info module already initialized"))?;

        Ok(())
    }
}

impl RestApiCapability for AuthInfoModule {
    fn register_rest(
        &self,
        _ctx: &ModuleCtx,
        router: Router,
        openapi: &dyn OpenApiRegistry,
    ) -> anyhow::Result<Router> {
        let config = self
            .config
            .get()
            .ok_or_else(|| anyhow::anyhow!("auth-info not initialized"))?
            .clone();

        let response = AuthInfoResponse {
            issuer_url: config.issuer_url.clone(),
            client_id: config.client_id.clone(),
            redirect_uri: config.redirect_uri.clone(),
            scopes: config.scopes.clone(),
            response_type: "code".to_owned(),
        };

        let handler = move || {
            let resp = response.clone();
            async move { Json(resp) }
        };

        let router = OperationBuilder::new(Method::GET, "/v1/auth/config")
            .summary("OIDC configuration for frontend")
            .description("Returns OIDC provider details for the Authorization Code flow with PKCE. No authentication required.")
            .public()
            .json_response(StatusCode::OK, "OIDC configuration")
            .standard_errors(openapi)
            .handler(handler)
            .register(router, openapi);

        tracing::info!("registered public endpoint: GET /v1/auth/config");
        Ok(router)
    }
}

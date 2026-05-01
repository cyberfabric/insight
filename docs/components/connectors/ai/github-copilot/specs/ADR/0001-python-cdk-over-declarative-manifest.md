---
status: accepted
date: 2026-04-26
decision_makers:
  - Sergei Mozhaev
---

# ADR-0001: Python CDK over Declarative Manifest

## Context

The GitHub Copilot metrics API (`/orgs/{org}/copilot/metrics/reports/users-1-day` and `/orgs/{org}/copilot/metrics/reports/organization-1-day`) delivers metric payloads via a two-step signed URL pattern:

1. **Step 1** — authenticated `GET` to `api.github.com` returns a JSON envelope: `{"download_links": [...], "report_day": "YYYY-MM-DD"}`.
2. **Step 2** — unauthenticated `GET` to each signed URL on `copilot-reports.github.com` returns an NDJSON payload (one JSON object per line).

Two implementation frameworks were considered:

1. **Airbyte declarative manifest** (`connector.yaml`) — used by `claude-admin`, `cursor`, and other AI connectors in this project.
2. **Airbyte Python CDK** (`AbstractSource`) — used by `github-v2` and other connectors with non-standard fetch patterns.

## Decision

Use the Airbyte Python CDK (`AbstractSource`).

## Rationale

Two technical constraints make the declarative manifest framework inapplicable:

1. **Authorization header suppression**: The signed URLs on `copilot-reports.github.com` are pre-authenticated. Sending an `Authorization` header to this domain may cause request failures. The declarative manifest `ApiKeyAuthenticator` and `BearerAuthenticator` always attach the configured auth header to every request — there is no per-request header override mechanism in the declarative framework.

2. **NDJSON parsing**: The signed URL response is NDJSON — each line is a separate JSON object; the payload as a whole is not valid JSON. The declarative manifest has no built-in NDJSON record extractor; it assumes the response is a single JSON document with a records array path.

The Python CDK (`AbstractSource` + `HttpStream`) provides direct control over per-request headers and allows implementing a custom `parse_response()` method for NDJSON line-by-line iteration.

## Consequences

- The connector is implemented as a Python CDK image (`source-github-copilot`) rather than a no-code declarative manifest.
- A custom Docker image is required, increasing CI build and maintenance surface compared to declarative connectors.
- The `_fetch_ndjson_records()` helper method encapsulates the two-step pattern and is reusable for any future stream that uses the same signed URL mechanism.
- If GitHub modifies the metrics API to return standard JSON (removing the NDJSON / signed URL pattern), the connector can be migrated to a declarative manifest to reduce maintenance burden.

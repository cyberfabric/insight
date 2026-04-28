---
status: proposed
date: 2026-04-28
---

# PRD -- BFF (Backend-for-Frontend) Service

<!-- toc -->

- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background--problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
  - [2.2 System Actors](#22-system-actors)
- [3. Operational Concept & Environment](#3-operational-concept--environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 OIDC Login Flow](#51-oidc-login-flow)
  - [5.2 Session Cookie](#52-session-cookie)
  - [5.3 Session Refresh](#53-session-refresh)
  - [5.4 Session Store](#54-session-store)
  - [5.5 Gateway JWT (Downstream Token)](#55-gateway-jwt-downstream-token)
  - [5.6 Session Management](#56-session-management)
  - [5.7 Logout](#57-logout)
  - [5.8 CSRF Protection](#58-csrf-protection)
  - [5.9 IdP Token Refresh (Internal)](#59-idp-token-refresh-internal)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The BFF is the auth half of the Insight API Gateway. It runs the OIDC login flow against the customer's identity provider, holds the user session server-side, and exposes a small `/auth/*` API that the SPA uses to log in, refresh, list devices, and log out.

The browser only ever holds an opaque session cookie with a short TTL. The IdP token never reaches the browser. The session is extended only by an explicit `POST /auth/refresh` from the SPA -- never by passive activity.

Request forwarding to internal services and gateway JWT minting are owned by the sibling [Router](../router/PRD.md), not by the BFF.

### 1.2 Background / Problem Statement

The current frontend stores the OIDC access token in `localStorage`. Any XSS leaks every active token. Storage-bound tokens are also visible to browser extensions and developer tools.

Moving the token to an `HttpOnly`, `Secure`, `SameSite=Strict` cookie alone is not enough. The token in the cookie still grants long-lived access, cannot be revoked without a denylist, and exposes IdP claims to the browser tier. We want:

1. The browser to hold only an opaque session ID -- nothing usable if leaked off-host.
2. The session to be revocable instantly, including "log out everywhere" for one user.
3. Internal services to verify caller identity statelessly via a short-lived JWT signed by the gateway, not by the IdP.

### 1.3 Goals (Business Outcomes)

- Remove all IdP and access tokens from browser storage.
- Make sessions revocable per-session and per-user from a single store.
- Give every internal service a verifiable, short-lived identity claim per request.
- Keep the SPA simple -- no token handling code in the browser.

### 1.4 Glossary

| Term | Definition |
|------|------------|
| OIDC token | ID token + access token + refresh token issued by the customer's identity provider. Consumed by the BFF, never seen by the browser. |
| Session cookie | Opaque, random session ID set on the browser by the BFF. Short, hard TTL. No claims, no meaning outside Redis. |
| Session record | Server-side object in Redis keyed by session ID. Holds user, tenant, IdP tokens, expiry. |
| Session refresh | Explicit `POST /auth/refresh` call from the SPA that extends the session TTL. The session does **not** extend automatically on regular API calls. |
| User session index | Redis sorted set keyed by user ID. Members are session IDs, score is `expires_at`. Lets the BFF list active sessions and find expired ones in O(log N). |
| Gateway JWT | Short-lived EdDSA-signed JWT minted by the [Router](../router/PRD.md) for each upstream call. Verified by internal services via JWKS. |
| Downstream service | Any internal Insight service behind the gateway (Analytics API, Connector Manager, Identity Service, etc.). |

## 2. Actors

### 2.1 Human Actors

#### Browser User

**ID**: `cpt-insightspec-actor-browser-user`

**Role**: Any authenticated end user (Viewer, Analyst, Admin) accessing Insight through the SPA.
**Needs**: Log in, stay logged in across requests, log out, see their active sessions, revoke a session from another device.

#### Tenant Administrator

**ID**: `cpt-insightspec-actor-tenant-admin`

**Role**: Already defined in the parent backend PRD. Additionally needs to revoke any user's sessions (forced logout on role change, offboarding, suspected compromise).

### 2.2 System Actors

#### OIDC Provider

**ID**: `cpt-insightspec-actor-oidc-provider`

**Role**: Customer identity provider. Runs the authorization code + PKCE flow. May call back-channel logout.

#### Downstream Service

**ID**: `cpt-insightspec-actor-downstream-service`

**Role**: Any internal Insight service that receives the gateway JWT from the BFF and authorizes the request based on its claims.

#### Redis

**ID**: `cpt-insightspec-actor-redis`

**Role**: Stores session records and the user-to-sessions index. The single source of truth for "who is logged in".

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Single deployment per Insight installation, fronted by the cluster ingress.
- Public hostname terminates TLS at the ingress; the BFF refuses requests received as plain HTTP.
- The BFF and the SPA are served from the same registrable domain so cookies are first-party.
- Stateless horizontally scalable -- all session state is in Redis.

## 4. Scope

### 4.1 In Scope

- OIDC authorization code + PKCE login flow as a confidential client.
- Opaque session cookie issuance with short hard TTL and hardened attributes.
- Explicit session refresh endpoint (`POST /auth/refresh`).
- Session record storage in Redis (BFF-prefixed keys) with a sorted-set per-user index keyed by `expires_at`.
- Session listing and revocation API (single, all-but-current, all).
- Logout: local, RP-initiated to OIDC provider, and OIDC back-channel logout receiver.
- Refresh of upstream IdP tokens (gateway ↔ IdP, internal -- not visible to the SPA).
- CSRF defense for state-changing requests.
- Periodic cleanup of expired session entries from the user index.

### 4.2 Out of Scope

- Gateway JWT minting and signing -- owned by the [Router](../router/PRD.md).
- JWKS endpoint -- served by the Router.
- Reverse-proxying `/api/*` requests -- owned by the Router.
- Authorization decisions inside downstream services (each service still enforces RBAC and visibility).
- User registration, password management, MFA -- handled by the customer OIDC provider.
- License / role / scope claims in the gateway JWT -- not needed for v1; only `sub` and `tid` are carried.
- Mobile or third-party API clients (v1 serves only the bundled SPA).

## 5. Functional Requirements

### 5.1 OIDC Login Flow

#### Authorization Code with PKCE

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-oidc-login`

The system **MUST** implement OIDC authorization code flow with PKCE as a confidential client. The BFF **MUST** generate `state`, `nonce`, and PKCE verifier per login attempt and validate them on callback. The browser **MUST NOT** receive or transmit the IdP code, ID token, or access token at any point.

**Rationale**: The whole point of this redesign -- IdP tokens never leave the server.

**Actors**: `cpt-insightspec-actor-browser-user`, `cpt-insightspec-actor-oidc-provider`

### 5.2 Session Cookie

#### Session Cookie Issuance

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-session-cookie`

After a successful OIDC callback, the system **MUST** issue an opaque session cookie with these attributes:

- `__Host-` prefix (forces host-only + Secure + Path=/).
- `HttpOnly`.
- `Secure`.
- `SameSite=Strict`.
- Random value with at least 128 bits of entropy.
- Short hard TTL. The TTL **MUST** be configurable; default is 120 seconds. The cookie `Max-Age` **MUST** match the session record TTL in Redis.
- The TTL **MUST NOT** be extended automatically by activity. Only an explicit `POST /auth/refresh` extends it (see 5.3).
- An absolute hard cap (e.g. 8h, configurable) **MUST** apply across refreshes -- once `created_at + max_lifetime` is reached, refresh fails and the user must log in again.

The cookie value **MUST** be opaque -- no claims, no JWT, no user-identifying data.

**Rationale**: Short TTL plus explicit refresh limits the window for stolen-cookie reuse and gives the SPA explicit control over session lifetime. The absolute cap forces re-authentication on a known schedule.

**Actors**: `cpt-insightspec-actor-browser-user`

### 5.3 Session Refresh

#### Explicit Session Refresh Endpoint

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-session-refresh`

The system **MUST** expose `POST /auth/refresh`. When called with a valid session cookie, it **MUST**:

1. Validate the session in Redis.
2. Reject (401) if the session is unknown, expired, or past the absolute lifetime cap.
3. Update the session record's `expires_at` to `now + session_ttl`.
4. Update the user-index sorted-set score for this session to the new `expires_at`.
5. Re-issue the session cookie with a fresh `Max-Age`.
6. (Internal, transparent to SPA) refresh the IdP access token if it is near expiry; on IdP refresh failure, revoke the session and return 401.
7. Return `200` with a JSON body containing `expires_at` (epoch seconds, absolute deadline) and `refresh_at` (epoch seconds, recommended next-refresh moment = `expires_at − safety_margin`). `safety_margin` is configurable, default 30 s.

The system **MUST NOT** extend the session on any other endpoint or proxied API call. Regular `/api/*` traffic does not slide the TTL.

The SPA uses `refresh_at` to schedule its next call. `GET /auth/me` **MUST** return the same two fields so the SPA can prime its timer at page load.

**Rationale**: Explicit refresh keeps idle sessions short-lived without sliding-TTL machinery on the hot path. Returning `refresh_at` lets the operator tune `session_ttl` without an SPA change.

**Actors**: `cpt-insightspec-actor-browser-user`

### 5.4 Session Store

#### Redis-Backed Session Storage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-session-store`

The system **MUST** store every session in Redis using BFF-owned key prefixes:

1. `bff:session:{session_id}` -- the session record: `user_id`, `tenant_id`, IdP `sub`, IdP `iss`, IdP `sid`, IdP access token, IdP refresh token, IdP access-token expiry, `created_at`, `expires_at`, `absolute_expires_at`, `user_agent`, `ip`, `csrf_token`. Redis TTL matches `expires_at`.
2. `bff:user_sessions:{user_id}` -- a Redis **sorted set** whose members are the user's `session_id` values and whose **score is `expires_at`** (epoch seconds). This lets the BFF:
   - List active sessions: `ZRANGEBYSCORE bff:user_sessions:{uid} <now> +inf`.
   - Find expired entries: `ZRANGEBYSCORE bff:user_sessions:{uid} 0 <now>` (cleaned up by the janitor; see 5.4 below).
3. `bff:sid_index:{iss}:{idp_sid}` -- a Redis set used to resolve OIDC back-channel logout tokens to local sessions.

Create, refresh, and revoke operations **MUST** mutate `bff:session:*` and `bff:user_sessions:*` atomically (Lua script or `MULTI`).

The system **MUST** run a periodic janitor that scans `bff:user_sessions:*`, removes members whose score is in the past, and emits a metric on drift between the index and the underlying records.

**Rationale**: Score-by-expiry gives O(log N) lookup of expired entries, which a plain set cannot. The `bff:` prefix avoids key-name collisions with the Router (`router:jwt_cache:*`) or any future module sharing the same Redis.

**Actors**: `cpt-insightspec-actor-redis`

### 5.5 Gateway JWT (Downstream Token)

#### Gateway JWT Claim Contract

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-gateway-jwt`

The gateway JWT is **minted by the Router** (see [Router PRD §5.2](../router/PRD.md#52-gateway-jwt-mint-and-cache)). The BFF defines the **claim contract** that the Router fills.

The gateway JWT **MUST** be signed with **EdDSA (Ed25519)** and **MUST** carry exactly the following claims, separated as required JWT claims and Insight-specific custom claims:

**Required JWT claims (RFC 7519)**:

- `iss` -- gateway issuer URL.
- `aud` -- `internal-services`.
- `sub` -- internal `user_id`.
- `iat` -- issued at (epoch seconds).
- `exp` -- `iat + 60..300` (hard bounds).
- `jti` -- UUID v7 for traceability.

**Insight custom claims**:

- `tid` -- `tenant_id`.
- `sid` -- BFF session ID (opaque, useful for tracing only).

**Out of scope for v1**: license tier (`lic`), roles, scopes. Authorization is performed inside each downstream service against its own data. These claims may be added in a later major version of the contract; until then, downstream services **MUST NOT** rely on them being present.

The Router **MUST** publish the public verification key at `/.well-known/jwks.json` on the gateway. **JWKS distribution to downstream services**: each downstream service is configured (Helm value `gateway.jwks_url`, env `GATEWAY_JWKS_URL`) with the absolute URL of the JWKS endpoint. Services fetch and cache the key set at startup and re-fetch on unknown `kid`. There is no service discovery; the URL is explicit.

Downstream services **MUST** verify the signature, `iss`, `aud`, and `exp` against the cached JWKS -- no shared secrets.

**Rationale**: Short TTL kills the need for a JWT denylist. EdDSA signatures are small and fast to verify. Explicit JWKS URL avoids guessing or service-mesh dependencies.

**Actors**: `cpt-insightspec-actor-downstream-service`

### 5.6 Session Management

#### List Active Sessions

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-session-list`

The system **MUST** expose an authenticated endpoint that returns the active sessions for the calling user (created_at, expires_at, user_agent, ip, current=true/false). The endpoint **MUST** read from the user-sessions sorted set with `ZRANGEBYSCORE`, returning only entries with score > now.

**Actors**: `cpt-insightspec-actor-browser-user`

#### Revoke Sessions

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-session-revoke`

The system **MUST** support three revocation operations:

1. Revoke the current session (logout).
2. Revoke a specific other session by ID.
3. Revoke all sessions for a user (self "log out everywhere", or admin-initiated).

Each operation **MUST** delete the session record(s) and remove them from `bff:user_sessions:{user_id}` (`ZREM`) atomically, and (when feasible) call the OIDC provider's RP-initiated logout. After revocation, any in-flight gateway JWT **MUST** become invalid within one JWT TTL (≤ 300 s).

**Rationale**: Instant revocation is the main reason to keep the session opaque + server-side. Without "all-sessions" revocation, offboarding and compromise response are broken.

**Actors**: `cpt-insightspec-actor-browser-user`, `cpt-insightspec-actor-tenant-admin`

### 5.7 Logout

#### Logout (Local, RP-Initiated, Back-Channel)

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-logout`

The system **MUST** provide `POST /auth/logout` that revokes the current session, clears the cookie (`Max-Age=0`), and redirects (or returns a redirect URL) to the OIDC `end_session_endpoint` for RP-initiated logout.

The system **MUST** accept OIDC back-channel logout tokens at a dedicated endpoint, validate the `logout_token` per spec, locate sessions by `(iss, sid)` or `(iss, sub)`, and revoke them.

**Rationale**: Without back-channel logout, IdP-side session termination does not propagate. Without RP-initiated logout, users stay signed in to the IdP after pressing "log out".

**Actors**: `cpt-insightspec-actor-oidc-provider`, `cpt-insightspec-actor-browser-user`

### 5.8 CSRF Protection

#### CSRF Defense

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-csrf`

For state-changing methods (POST, PUT, PATCH, DELETE) on `/auth/*`, the system **MUST** require either:

1. A double-submit CSRF token sent in `X-CSRF-Token` matching a value bound to the session, or
2. A verified `Origin` header matching the configured SPA origin.

`SameSite=Strict` is the primary defense; this requirement is the second line.

**Rationale**: `SameSite=Strict` mitigates most CSRF, but defense in depth is cheap and protects against same-site-but-different-path attack vectors.

**Actors**: `cpt-insightspec-actor-browser-user`

### 5.9 IdP Token Refresh (Internal)

#### IdP Access Token Refresh

- [ ] `p1` - **ID**: `cpt-insightspec-fr-bff-idp-refresh`

When the IdP access token stored in the session is near expiry, the system **MUST** refresh it using the stored refresh token. On refresh failure, the system **MUST** revoke the session and force the user to log in again.

This is **internal**, not visible to the SPA. It is distinct from session refresh (5.3) which is a browser-initiated, user-visible TTL extension. IdP refresh is only triggered when the BFF needs a valid IdP access token (e.g. on `/auth/refresh`, on logout to call RP-initiated logout, or if a future feature calls IdP-protected APIs on the user's behalf).

**Rationale**: The browser does not handle IdP tokens. Failed refresh means the IdP no longer trusts this user, so the session goes too.

**Actors**: `cpt-insightspec-actor-oidc-provider`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### HTTPS Enforcement

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bff-https-only`

The system **MUST** reject all plain-HTTP requests at the ingress. The system **MUST** set `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload` on every response.

**Threshold**: Zero responses served over HTTP.

#### Session Lookup Latency

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-bff-session-lookup-p95`

Session validation against Redis **MUST** complete within 5 ms p95 under normal load.

**Threshold**: 5 ms p95 Redis read.

#### Session TTL Bounds

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bff-session-ttl`

The session TTL **MUST** be configurable. Allowed range: 30 seconds to 1 hour. Default: 120 seconds. The absolute lifetime cap **MUST** be configurable; default 8 hours; minimum 1 hour; maximum 24 hours.

**Threshold**: Operator can set both knobs via Helm values without code change.

#### Gateway JWT Algorithm

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bff-jwt-algorithm`

The gateway JWT **MUST** be signed with EdDSA (Ed25519). No other algorithm is permitted.

**Threshold**: 100% of issued JWTs use `alg: EdDSA`. Any other algorithm in JWKS or in a token is rejected by downstream services.

#### Cookie Hardening

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bff-cookie-attrs`

Every session cookie response **MUST** include `__Host-` prefix, `HttpOnly`, `Secure`, `SameSite=Strict`, `Path=/`, and no `Domain` attribute. A request that would set a session cookie without all of these **MUST** fail closed.

**Threshold**: 100% of session-cookie responses match the attribute set.

#### Audit of Auth Events

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-bff-audit`

Every login, logout, session refresh, IdP token refresh failure, session revocation, and back-channel logout **MUST** emit an audit event consumed by the Audit Service (see parent PRD `cpt-insightspec-fr-be-audit-trail`).

**Threshold**: 100% coverage of auth events.

### 6.2 NFR Exclusions

- **Per-route rate limiting in the BFF**: Handled by the surrounding ingress and per-service middleware. The BFF only rate-limits `/auth/*` endpoints (login, callback, refresh) to slow brute force.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Auth API

- [ ] `p1` - **ID**: `cpt-insightspec-interface-bff-auth-api`

**Type**: REST API

**Stability**: stable

**Endpoints**:

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/auth/login` | Start OIDC flow; 302 to IdP. |
| GET | `/auth/callback` | OIDC callback; sets session cookie; 302 to SPA. |
| POST | `/auth/refresh` | Extend session TTL; re-issue cookie; return `{expires_at, refresh_at}`. SPA schedules next call from `refresh_at`. |
| POST | `/auth/logout` | Revoke current session; clear cookie; return RP-logout URL. |
| GET | `/auth/me` | Return current user, tenant, plus `{expires_at, refresh_at}` so the SPA can prime its refresh timer at page load. |
| GET | `/auth/sessions` | List active sessions for current user. |
| DELETE | `/auth/sessions/{id}` | Revoke a specific session. |
| DELETE | `/auth/sessions` | Revoke all sessions of current user. |
| POST | `/auth/oidc/back-channel-logout` | Receive IdP back-channel logout tokens. |
| GET | `/auth/csrf` | Issue CSRF token bound to current session. |

JWKS publication and `/api/*` reverse proxy live on the [Router](../router/PRD.md), not on the BFF, but they share the same hostname and TLS endpoint.

### 7.2 External Integration Contracts

#### Gateway JWT Claim Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-bff-gateway-jwt`

**Direction**: defined by BFF, minted by Router, consumed by every downstream service.

**Format**: EdDSA-signed JWT.

**Required JWT claims**: `iss`, `aud`, `sub`, `iat`, `exp`, `jti`.

**Insight custom claims**: `tid`, `sid`.

**Compatibility**: Additive custom claims only without a major version. Removing or changing the meaning of any claim requires a major version bump and coordinated rollout. License / role / scope claims are deliberately not present in v1.

#### JWKS Distribution Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-bff-jwks-url`

**Direction**: configuration -- each downstream service is given the JWKS URL.

**Mechanism**: Helm value `gateway.jwks_url` and matching env `GATEWAY_JWKS_URL` injected into each downstream service. Default value points at the gateway's `/.well-known/jwks.json`. Services fetch on startup, cache 1 h, refetch on unknown `kid`.

**Compatibility**: URL is stable across minor releases. Schema follows RFC 7517 JWKS.

#### OIDC Provider Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-bff-oidc`

**Direction**: required from customer.

**Protocol**: OIDC Authorization Code + PKCE; refresh tokens; RP-initiated logout (`end_session_endpoint`); back-channel logout per OIDC spec.

**Compatibility**: Standard OIDC. Customer IdP must support all four.

## 8. Use Cases

#### Login

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-bff-login`

**Actor**: `cpt-insightspec-actor-browser-user`

**Preconditions**: SPA loaded; no valid session cookie.

**Main Flow**:
1. SPA calls a protected API; Router returns 401 with login URL.
2. Browser requests `/auth/login`. BFF generates `state`, `nonce`, PKCE verifier; stores them in `bff:login_state:{state}`; redirects to IdP.
3. User authenticates at IdP. IdP redirects browser to `/auth/callback` with code.
4. BFF validates `state`, exchanges code (with PKCE verifier) for tokens, validates ID token (`nonce`, `iss`, `aud`, signature, expiry).
5. BFF resolves IdP `sub` to internal user (Identity Service).
6. BFF creates `bff:session:{id}` and `ZADD bff:user_sessions:{user_id} {expires_at} {sid}`.
7. BFF sets the session cookie (short TTL) and redirects to the SPA's original target.

**Postconditions**: Browser holds a session cookie. Redis holds the session record and a sorted-set entry whose score is the session's `expires_at`. Audit event recorded.

**Alternative Flows**:
- **State or nonce mismatch**: BFF returns 400 and aborts. No session created.
- **IdP-resolved user not found**: BFF returns 403; audit event records the failed login.

#### Session Refresh

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-bff-refresh`

**Actor**: `cpt-insightspec-actor-browser-user`

**Preconditions**: Valid session cookie; current time before `absolute_expires_at`.

**Main Flow**:
1. SPA calls `POST /auth/refresh`. The cadence is driven by the `refresh_at` value the SPA received in the previous response.
2. BFF reads the cookie, fetches `bff:session:{id}`.
3. BFF computes `new_expires_at = min(now + session_ttl, absolute_expires_at)`.
4. BFF runs a Lua script that updates `bff:session:{id}` and `ZADD bff:user_sessions:{user_id} new_expires_at sid` atomically.
5. (If IdP access token is near expiry) BFF refreshes it via the IdP refresh token.
6. BFF re-issues the cookie with `Max-Age = new_expires_at − now` and returns `200` with body `{expires_at: new_expires_at, refresh_at: new_expires_at − safety_margin}`.

**Postconditions**: Session lives for another TTL window. ZSET score updated. SPA has the next `refresh_at` to schedule from.

**Alternative Flows**:
- **Session unknown or expired**: 401, cookie cleared.
- **Past absolute cap**: 401, session revoked.
- **IdP refresh fails**: session revoked, 401.

#### Log Out Everywhere

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-bff-logout-everywhere`

**Actor**: `cpt-insightspec-actor-browser-user`

**Main Flow**:
1. User triggers "log out everywhere" in the SPA.
2. SPA calls `DELETE /auth/sessions`.
3. BFF reads `bff:user_sessions:{user_id}` (`ZRANGEBYSCORE 0 +inf`), deletes every `bff:session:{sid}`, deletes the sorted set, instructs the Router to drop matching `router:jwt_cache:{sid}` entries.
4. BFF clears the current cookie. Audit events recorded for each session.

**Postconditions**: All cookies still in browsers point to nonexistent sessions; next request from any device returns 401. Within one gateway-JWT TTL, all in-flight requests fail.

**Alternative Flows**:
- **Admin-initiated**: Tenant Admin calls the same operation against a target user; permission check enforces admin scope.

#### Back-Channel Logout

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-bff-back-channel-logout`

**Actor**: `cpt-insightspec-actor-oidc-provider`

**Main Flow**:
1. IdP terminates a user's IdP session and POSTs a `logout_token` to `/auth/oidc/back-channel-logout`.
2. BFF validates the logout token (signature, `iss`, `aud`, `iat`, `events` claim).
3. BFF resolves `(iss, sid)` (or `sub`) to the matching session(s) and revokes them.

**Postconditions**: User's session is gone. Next browser request returns 401.

## 9. Acceptance Criteria

- [ ] `cpt-insightspec-fr-bff-oidc-login`, `cpt-insightspec-fr-bff-session-cookie`: After login, no IdP token is present in any cookie, header, or response body delivered to the browser. The only auth artifact in the browser is the opaque session cookie with `__Host-`, `HttpOnly`, `Secure`, `SameSite=Strict`, and a `Max-Age` matching the configured session TTL.
- [ ] `cpt-insightspec-fr-bff-session-refresh`: Without `/auth/refresh` calls, a session expires after `session_ttl` seconds regardless of `/api/*` activity. With periodic refresh, sessions live until the absolute cap.
- [ ] `cpt-insightspec-fr-bff-session-store`: Every active session appears at `bff:session:{id}` and as a member of `bff:user_sessions:{user_id}` with score = `expires_at`. A revocation removes both atomically. The janitor reduces drift to zero on each pass.
- [ ] `cpt-insightspec-fr-bff-session-list`, `cpt-insightspec-fr-bff-session-revoke`: A user can list their active sessions (only entries with score > now) and revoke one, all-but-current, or all. After "revoke all", every device returns 401 within one gateway-JWT TTL.
- [ ] `cpt-insightspec-fr-bff-gateway-jwt`: The Router-issued gateway JWT carries exactly `iss`, `aud`, `sub`, `iat`, `exp`, `jti`, `tid`, `sid` -- nothing else. Signed with EdDSA. Verifiable by downstream services against the JWKS URL configured in their Helm values.
- [ ] `cpt-insightspec-fr-bff-logout`: Local logout, RP-initiated logout, and back-channel logout all converge on session deletion plus user-index cleanup.
- [ ] `cpt-insightspec-fr-bff-csrf`: State-changing `/auth/*` requests without a valid CSRF token or matching `Origin` are rejected with 403.
- [ ] `cpt-insightspec-nfr-bff-https-only`: No HTTP request reaches application code; HSTS is set on every response.
- [ ] `cpt-insightspec-nfr-bff-session-ttl`: Operator can set `session_ttl` and `absolute_lifetime` via Helm values; values within the documented ranges take effect on rolling restart.

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Redis | Session records and user-sessions sorted set | `p1` |
| Customer OIDC provider | Authentication, refresh, logout | `p1` |
| Identity Service | Map IdP `sub` to internal `user_id` and tenant | `p1` |
| Audit Service | Sink for auth events | `p1` |
| Ingress / TLS terminator | HTTPS termination, HSTS, request routing | `p1` |
| Router (sibling) | Gateway JWT minting, JWKS, `/api/*` reverse proxy | `p1` |

## 11. Assumptions

- The customer OIDC provider supports authorization code + PKCE, refresh tokens, RP-initiated logout, and back-channel logout.
- The SPA and BFF are served from the same registrable domain (first-party cookies).
- The SPA can poll `/auth/refresh` on a fixed cadence and handle 401 by redirecting to `/auth/login`.
- Redis is deployed in HA mode; session loss requires re-login for affected users -- acceptable.

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| SPA stops calling `/auth/refresh` (bug, throttled tab) | User is logged out mid-flow | Default TTL of 120 s with 60 s refresh cadence gives 60 s of slack; document recommended cadence; SPA must handle 401 cleanly |
| Redis outage | All users effectively logged out; logins blocked | HA Redis; degraded mode policy deferred to DESIGN |
| BFF on the auth-critical path | Single point of failure for all UI traffic | Stateless horizontal scaling; readiness probes; ingress retries |
| `SameSite=Strict` breaks deep links from external sites | User lands logged out when following email/Slack links | Documented behavior; fall back to `Lax` only if UX requires it |
| Janitor falls behind | `bff:user_sessions:*` accumulates expired entries | Metric on backlog size; alert when above threshold; pass interval is shorter than session TTL |
| Back-channel logout endpoint abuse | Spoofed logout tokens trigger session revocation | Strict OIDC `logout_token` validation: signature, `iss`, `aud`, `iat`, `events`, `jti` replay protection |
| User-sessions index drift | Index lists sessions that no longer exist (or vice versa) | Atomic ops via Lua script; janitor reconciles |

---
status: proposed
date: 2026-04-28
---

# DESIGN -- BFF (Backend-for-Frontend) Service

- [ ] `p3` - **ID**: `cpt-insightspec-design-bff`

<!-- toc -->

- [1. Architecture Overview](#1-architecture-overview)
  - [1.1 Architectural Vision](#11-architectural-vision)
  - [1.2 Architecture Drivers](#12-architecture-drivers)
  - [1.3 Architecture Layers](#13-architecture-layers)
- [2. Principles & Constraints](#2-principles--constraints)
  - [2.1 Design Principles](#21-design-principles)
  - [2.2 Constraints](#22-constraints)
- [3. Technical Architecture](#3-technical-architecture)
  - [3.1 Domain Model](#31-domain-model)
  - [3.2 Component Model](#32-component-model)
  - [3.3 API Contracts](#33-api-contracts)
  - [3.4 Internal Dependencies](#34-internal-dependencies)
  - [3.5 External Dependencies](#35-external-dependencies)
  - [3.6 Interactions & Sequences](#36-interactions--sequences)
  - [3.7 Database schemas & tables](#37-database-schemas--tables)
  - [3.8 Gateway JWT Claim Contract](#38-gateway-jwt-claim-contract)
  - [3.9 Boundary with the Router](#39-boundary-with-the-router)
- [4. Cross-Cutting Concerns](#4-cross-cutting-concerns)
  - [4.1 Cookie Hardening](#41-cookie-hardening)
  - [4.2 CSRF Defense](#42-csrf-defense)
  - [4.3 Janitor for Expired Sessions](#43-janitor-for-expired-sessions)
  - [4.4 Observability](#44-observability)
- [5. Design Decisions](#5-design-decisions)
  - [DD-BFF-01: Opaque Session vs JWT Cookie](#dd-bff-01-opaque-session-vs-jwt-cookie)
  - [DD-BFF-02: Explicit Session Refresh, No Sliding TTL](#dd-bff-02-explicit-session-refresh-no-sliding-ttl)
  - [DD-BFF-03: ZSET (Not SET) for User-Session Index](#dd-bff-03-zset-not-set-for-user-session-index)
  - [DD-BFF-04: BFF-Prefixed Redis Keys](#dd-bff-04-bff-prefixed-redis-keys)
  - [DD-BFF-05: EdDSA Algorithm for Gateway JWT Contract](#dd-bff-05-eddsa-algorithm-for-gateway-jwt-contract)
  - [DD-BFF-06: Redis Outage = No Auth (Fail Closed)](#dd-bff-06-redis-outage--no-auth-fail-closed)
  - [DD-BFF-07: `/auth/refresh` Returns Next-Refresh Deadline](#dd-bff-07-authrefresh-returns-next-refresh-deadline)
  - [DD-BFF-08: `SameSite=Strict` Today, Pluggable Cookie Classes Later](#dd-bff-08-samesitestrict-today-pluggable-cookie-classes-later)
  - [DD-BFF-09: Janitor Coordinates via Redis Lock](#dd-bff-09-janitor-coordinates-via-redis-lock)
- [6. Traceability](#6-traceability)

<!-- /toc -->

---

## 1. Architecture Overview

### 1.1 Architectural Vision

The BFF is the auth half of the API Gateway. It owns the OIDC handshake, the session lifecycle, and the `/auth/*` API the SPA talks to. It does **not** mint gateway JWTs and does **not** proxy `/api/*` -- both belong to the sibling [Router](../router/DESIGN.md).

The browser-facing contract is small and explicit: one opaque session cookie with a short hard TTL, extended only by `POST /auth/refresh`. No sliding TTL, no implicit extension on activity. The SPA decides when the user is "active" by calling refresh on a cadence below the TTL.

All session state lives in Redis under the `bff:` key prefix. The BFF process is stateless beyond its config and JWT signing keys are not its concern.

The BFF is built on **cyberfabric-core ModKit** (same framework as the rest of the backend) and runs in the same pod as the Router.

### 1.2 Architecture Drivers

#### Functional Drivers

| Requirement | Design Response |
|---|---|
| `cpt-insightspec-fr-bff-oidc-login` | Confidential OIDC client with PKCE; tokens stored in Redis only |
| `cpt-insightspec-fr-bff-session-cookie` | `__Host-`-prefixed opaque session ID with short configurable TTL, set on `/auth/callback` |
| `cpt-insightspec-fr-bff-session-refresh` | `POST /auth/refresh` runs Lua script that extends `bff:session:{id}` and updates `ZADD` score |
| `cpt-insightspec-fr-bff-session-store` | `bff:session:{id}` HASH + `bff:user_sessions:{user_id}` ZSET with score = `expires_at` |
| `cpt-insightspec-fr-bff-session-list` | `ZRANGEBYSCORE bff:user_sessions:{uid} <now> +inf` |
| `cpt-insightspec-fr-bff-session-revoke` | Single Lua script removes session record(s) and `ZREM` from index; instructs Router to drop `router:jwt_cache:{sid}` |
| `cpt-insightspec-fr-bff-gateway-jwt` | Claim contract owned here; minting performed by Router |
| `cpt-insightspec-fr-bff-logout` | `/auth/logout` for local + RP-initiated; `/auth/oidc/back-channel-logout` for IdP-initiated |
| `cpt-insightspec-fr-bff-csrf` | Double-submit token bound to session ID + `Origin` allowlist |
| `cpt-insightspec-fr-bff-idp-refresh` | BFF refreshes IdP access token on demand using stored refresh token; failure → session revoke |

#### NFR Allocation

| NFR | Component | Verification |
|---|---|---|
| `cpt-insightspec-nfr-bff-https-only` | Ingress + middleware reject plain HTTP; HSTS header set globally | Curl over HTTP returns 308/400; `Strict-Transport-Security` present on every response |
| `cpt-insightspec-nfr-bff-session-lookup-p95` | Redis pipelined HMGET; no extra DB call on hot path | Load test, measure p95 |
| `cpt-insightspec-nfr-bff-session-ttl` | `session_ttl` and `absolute_lifetime` from Helm values; cookie `Max-Age` and Redis TTL match | Integration test sets TTLs; verify cookie + Redis expire together |
| `cpt-insightspec-nfr-bff-jwt-algorithm` | EdDSA-only contract on the JWT minted by the Router | Reject any non-EdDSA token in downstream verification tests |
| `cpt-insightspec-nfr-bff-cookie-attrs` | Single `set_session_cookie` helper; fail-closed if attribute set incomplete | Snapshot test on `Set-Cookie` headers |
| `cpt-insightspec-nfr-bff-audit` | Auth events published to Redpanda topic consumed by Audit Service | Integration test verifies event emission per auth action |

#### Architecture Decision Records

ADRs to be authored alongside implementation; decisions captured inline in §5 (Design Decisions) until then:

- Opaque server-side session, not JWT, for the browser-facing cookie -- see DD-BFF-01.
- Session TTL extended only by explicit `POST /auth/refresh` -- see DD-BFF-02.
- ZSET (not SET) for `bff:user_sessions:*` -- see DD-BFF-03.

### 1.3 Architecture Layers

```mermaid
graph TB
    subgraph Browser
        SPA[React SPA]
    end

    subgraph Ingress
        ING[Ingress<br/>TLS · HSTS]
    end

    subgraph GW["API Gateway pod"]
        BFF["BFF module<br/>/auth/*"]
        ROUTER["Router module<br/>/api/* + JWKS"]
        SM["Session Manager (lib)<br/>shared, owned by BFF"]
    end

    subgraph State
        RD[(Redis<br/>bff:* keys)]
    end

    subgraph External["External Systems"]
        OIDC[Customer OIDC Provider]
        ID[Identity Service]
        AU[Audit Service]
    end

    SPA -->|cookie| ING
    ING --> BFF
    ING --> ROUTER
    BFF --> SM
    ROUTER --> SM
    SM --> RD
    BFF <-->|auth code + PKCE,<br/>refresh, RP-logout| OIDC
    OIDC -.->|back-channel logout| BFF
    BFF -->|sub → user_id| ID
    BFF -->|audit events| AU
```

| Layer | Responsibility | Technology |
|---|---|---|
| Edge | TLS termination, HSTS, host routing | K8s ingress |
| Auth | OIDC handshake, session lifecycle, CSRF, `/auth/*` API | ModKit + `openidconnect` Rust crate |
| State | Sessions, user-sessions ZSET, login state, sid index | Redis (cluster mode optional) |
| Sibling | Gateway JWT mint + JWKS + `/api/*` proxy | [Router](../router/DESIGN.md) |

- [ ] `p3` - **ID**: `cpt-insightspec-tech-bff`

## 2. Principles & Constraints

### 2.1 Design Principles

#### Opaque to the browser

- [ ] `p2` - **ID**: `cpt-insightspec-principle-bff-opaque-cookie`

The browser only ever sees an opaque session ID. No JWTs, no IdP tokens, no claims. A stolen cookie buys access only on this host until the next TTL boundary.

#### Explicit refresh, no sliding TTL

- [ ] `p2` - **ID**: `cpt-insightspec-principle-bff-explicit-refresh`

The session TTL is short and hard. Extension only happens via `POST /auth/refresh`, called by the SPA on a fixed cadence. Regular API traffic never extends the session. This keeps the model simple, predictable, and easy to reason about.

#### Stateless service, stateful store

- [ ] `p2` - **ID**: `cpt-insightspec-principle-bff-stateless`

The BFF process holds no session state. Any pod can serve any request. All session state goes through Redis.

#### Fail closed on auth

- [ ] `p2` - **ID**: `cpt-insightspec-principle-bff-fail-closed`

If Redis is unreachable, the cookie is malformed, the session is past its absolute cap, or the IdP rejects a refresh -- return 401 and clear the cookie. Never serve a request with a guess.

### 2.2 Constraints

#### First-party cookie domain

- [ ] `p2` - **ID**: `cpt-insightspec-constraint-bff-same-domain`

The SPA and the gateway must be served from the same registrable domain. `__Host-` forbids `Domain=` and pins the cookie to one host.

#### OIDC provider feature set

- [ ] `p2` - **ID**: `cpt-insightspec-constraint-bff-oidc-features`

Customer IdP must support: authorization code with PKCE, refresh tokens, RP-initiated logout, and OIDC back-channel logout.

## 3. Technical Architecture

### 3.1 Domain Model

| Entity | Purpose | Storage |
|---|---|---|
| `Session` | Active browser session for one user on one device | Redis HASH `bff:session:{id}` |
| `UserSessionIndex` | All session IDs for one user, scored by expiry | Redis ZSET `bff:user_sessions:{user_id}` |
| `SidIndex` | Map (OIDC issuer, OIDC sid) → local session IDs | Redis SET `bff:sid_index:{iss}:{idp_sid}` |
| `LoginState` | Per-login transient state (PKCE verifier, nonce) | Redis HASH `bff:login_state:{state}`, TTL 5 min |

Relationships:
- `User` (owned by Identity Service) → 0..N `Session`
- `Session` → 1 `User`
- `Session` → 0..1 entry in `SidIndex` (only if IdP supplies `sid`)

### 3.2 Component Model

```mermaid
graph LR
    subgraph BFF
        ROUTER[HTTP Router<br/>axum]
        AUTHCTL[Auth Controller<br/>/auth/*]
        SESSMGR[Session Manager<br/>shared lib]
        OIDCCLT[OIDC Client]
        CSRF[CSRF Verifier]
        AUDIT[Audit Emitter]
        JANITOR[Expired-Session Janitor]
    end

    subgraph Ext
        REDIS[(Redis)]
        IDP[OIDC Provider]
        IDSVC[Identity Service]
        REDPANDA[Redpanda]
    end

    ROUTER --> AUTHCTL
    AUTHCTL --> OIDCCLT
    AUTHCTL --> SESSMGR
    AUTHCTL --> CSRF
    AUTHCTL --> AUDIT
    AUTHCTL --> IDSVC
    SESSMGR --> REDIS
    OIDCCLT --> IDP
    AUDIT --> REDPANDA
    JANITOR --> REDIS
```

#### Auth Controller

- [ ] `p2` - **ID**: `cpt-insightspec-component-bff-auth-controller`

##### Why this component exists
The single owner of every endpoint under `/auth/*` -- the only place where session state changes start. Without it, session creation, refresh, and revocation would be scattered across the codebase.

##### Responsibility scope
Login start, OIDC callback, session refresh, logout, session list / revoke (single + all), back-channel logout receiver, CSRF token issuance, `/auth/me`.

##### Responsibility boundaries
Does not authorize business operations -- downstream services do that. Does not own user data -- Identity Service does. Does not mint gateway JWTs or proxy `/api/*` -- the Router does.

##### Related components (by ID)
- `cpt-insightspec-component-bff-session-manager` -- creates / reads / refreshes / revokes sessions.
- `cpt-insightspec-component-bff-oidc-client` -- runs the OIDC handshake.
- `cpt-insightspec-component-bff-csrf-verifier` -- issues and checks CSRF tokens.
- `cpt-insightspec-component-bff-audit-emitter` -- publishes auth events.

#### Session Manager (shared library)

- [ ] `p2` - **ID**: `cpt-insightspec-component-bff-session-manager`

##### Why this component exists
The single entry point for every read or write of session state. Centralising Redis access here keeps atomicity guarantees and metrics uniform, and lets the Router link to the same code as a library for read-only session validation.

##### Responsibility scope
Create, read, refresh, list-by-user, revoke (single, all-but-current, all). Owns the Lua scripts (`create_session`, `refresh_session`, `revoke_session`, `revoke_user`) that keep `bff:session:*` and `bff:user_sessions:*` consistent.

##### Responsibility boundaries
Does not call the OIDC provider. Does not authenticate requests by itself -- callers (Auth Controller, Router) do. Does not own the cookie format.

##### Related components (by ID)
- `cpt-insightspec-component-bff-auth-controller` -- primary writer.
- `cpt-insightspec-component-router-auth` (Router-side) -- read-only consumer.

#### OIDC Client

- [ ] `p2` - **ID**: `cpt-insightspec-component-bff-oidc-client`

##### Why this component exists
Encapsulates the OIDC protocol so the rest of the BFF treats it as a small set of operations: authorize, exchange, refresh, end-session, validate logout token.

##### Responsibility scope
Authorization code + PKCE flow, ID token validation (`iss`, `aud`, `nonce`, `exp`, signature), access-token refresh, RP-initiated logout, back-channel logout token validation per OIDC spec.

##### Responsibility boundaries
Does not store sessions. Does not maintain user-side state. Holds no IdP tokens beyond the lifetime of one operation.

##### Related components (by ID)
- `cpt-insightspec-component-bff-auth-controller` -- only caller.
- `cpt-insightspec-component-bff-session-manager` -- recipient of the tokens that result from each OIDC operation.

#### CSRF Verifier

- [ ] `p2` - **ID**: `cpt-insightspec-component-bff-csrf-verifier`

##### Why this component exists
Provides defence-in-depth on top of `SameSite=Strict` for state-changing `/auth/*` methods.

##### Responsibility scope
Issue per-session CSRF tokens at login (and rotate on privilege change), constant-time compare them on POST/PUT/PATCH/DELETE, fall back to verifying `Origin` against the allowlist when no token is present.

##### Responsibility boundaries
Does not protect `/api/*` -- those rely on `SameSite=Strict` and the ingress. Does not store the token outside the session record.

##### Related components (by ID)
- `cpt-insightspec-component-bff-auth-controller` -- consumer.
- `cpt-insightspec-component-bff-session-manager` -- holds `csrf_token` inside `bff:session:*`.

#### Audit Emitter

- [ ] `p2` - **ID**: `cpt-insightspec-component-bff-audit-emitter`

##### Why this component exists
Centralises audit event publication so every auth-relevant action lands on the Redpanda topic with the same envelope and correlation fields.

##### Responsibility scope
Publish auth events (login OK / fail, refresh OK / fail, logout, IdP-refresh-fail, revoke single / all / admin, back-channel logout) to the audit topic consumed by Audit Service.

##### Responsibility boundaries
Does not run audit policy or retention -- Audit Service does. Does not log to disk -- the standard logger does.

##### Related components (by ID)
- `cpt-insightspec-component-bff-auth-controller` -- only caller.

#### Expired-Session Janitor

- [ ] `p2` - **ID**: `cpt-insightspec-component-bff-janitor`

##### Why this component exists
Per-session Redis TTL removes the record itself, but the user-index ZSET still lists the expired `session_id` until it is explicitly removed. Without the janitor, the index grows unbounded for users who never log out.

##### Responsibility scope
Periodic pass that elects one pod via a Redis lock, scans `bff:user_sessions:*`, and trims expired members with `ZREMRANGEBYSCORE`. Emits backlog and removed-count metrics.

##### Responsibility boundaries
Does not delete session records (they expire on their own). Does not run on every BFF pod simultaneously -- one elected pod per pass.

##### Related components (by ID)
- `cpt-insightspec-component-bff-session-manager` -- shares the same key conventions; janitor reads only.

### 3.3 API Contracts

- [ ] `p2` - **ID**: `cpt-insightspec-design-bff-auth-api-spec`

This section specifies the implementation of the auth API declared in [PRD §7.1](./PRD.md#71-public-api-surface) (`cpt-insightspec-interface-bff-auth-api`).

- **Contracts**: `cpt-insightspec-contract-bff-gateway-jwt`, `cpt-insightspec-contract-bff-oidc`, `cpt-insightspec-contract-bff-jwks-url`
- **Technology**: REST / OpenAPI 3.1
- **Location**: [openapi.yaml](./openapi.yaml) -- to be authored alongside implementation

| Method | Path | Auth | Description | Stability |
|---|---|---|---|---|
| GET | `/auth/login` | none | Start OIDC flow; 302 to IdP | stable |
| GET | `/auth/callback` | none | OIDC redirect target; sets session cookie | stable |
| POST | `/auth/refresh` | session | Extend session TTL, re-issue cookie | stable |
| POST | `/auth/logout` | session | Revoke current session, clear cookie, return RP-logout URL | stable |
| GET | `/auth/me` | session | Return current user and tenant | stable |
| GET | `/auth/sessions` | session | List active sessions for current user | stable |
| DELETE | `/auth/sessions/{id}` | session | Revoke a specific session | stable |
| DELETE | `/auth/sessions` | session | Revoke all sessions of current user | stable |
| POST | `/auth/oidc/back-channel-logout` | OIDC `logout_token` | IdP-initiated logout receiver | stable |
| GET | `/auth/csrf` | session | Issue CSRF token for the session | stable |

JWKS and `/api/*` reverse proxy live in the [Router](../router/DESIGN.md), not here.

### 3.4 Internal Dependencies

| Dependency | Interface | Purpose |
|---|---|---|
| Identity Service | REST (SDK client) | Resolve IdP `sub` → internal `user_id` and `tenant_id` |
| Audit Service | Redpanda producer | Publish auth events |
| Router (sibling) | In-process function calls (cache invalidation) | Notify Router to drop `router:jwt_cache:{sid}` on revoke |

### 3.5 External Dependencies

| System | Protocol | Purpose |
|---|---|---|
| Customer OIDC provider | OIDC 1.0 (HTTPS) | Login, refresh, RP-initiated logout, back-channel logout |
| Redis | RESP (TCP/TLS) | Session store + user-sessions index |

### 3.6 Interactions & Sequences

#### Login (OIDC Authorization Code + PKCE)

**ID**: `cpt-insightspec-seq-bff-login`

**Use cases**: `cpt-insightspec-usecase-bff-login`

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant B as BFF
    participant R as Redis
    participant I as OIDC Provider
    participant ID as Identity Service

    U->>B: GET /auth/login
    B->>B: generate state, nonce, PKCE verifier
    B->>R: SETEX bff:login_state:{state} 5min
    B-->>U: 302 to IdP authorize URL
    U->>I: authorize(code_challenge, state)
    I-->>U: 302 /auth/callback?code&state
    U->>B: GET /auth/callback
    B->>R: GET bff:login_state:{state}
    R-->>B: {verifier, nonce}
    B->>I: token exchange (code, verifier)
    I-->>B: id_token, access_token, refresh_token
    B->>B: validate id_token
    B->>ID: resolve(sub) → user_id, tenant_id
    ID-->>B: user_id, tenant_id
    B->>R: EVAL create_session.lua<br/>HSET bff:session:{sid} ...<br/>ZADD bff:user_sessions:{uid} expires_at sid<br/>SADD bff:sid_index:{iss}:{idp_sid} sid
    R-->>B: OK
    B-->>U: 302 to SPA + Set-Cookie __Host-sid<br/>(HttpOnly,Secure,Strict, Max-Age=session_ttl)
```

#### Session Refresh

**ID**: `cpt-insightspec-seq-bff-refresh`

**Use cases**: `cpt-insightspec-usecase-bff-refresh`

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant B as BFF
    participant R as Redis
    participant I as OIDC Provider

    U->>B: POST /auth/refresh (cookie __Host-sid)
    B->>R: HMGET bff:session:{sid}
    R-->>B: session
    B->>B: check now < absolute_expires_at
    B->>B: new_exp = min(now + session_ttl, absolute_expires_at)
    alt IdP access_token near expiry
        B->>I: refresh_token grant
        I-->>B: new access_token
    end
    B->>R: EVAL refresh_session.lua<br/>HSET bff:session:{sid} expires_at new_exp<br/>ZADD bff:user_sessions:{uid} new_exp sid<br/>EXPIREAT bff:session:{sid} new_exp
    R-->>B: OK
    B-->>U: 200 {expires_at: new_exp, refresh_at: new_exp - safety_margin}<br/>Set-Cookie __Host-sid Max-Age=(new_exp - now)
```

#### IdP Token Refresh Failure

**ID**: `cpt-insightspec-seq-bff-idp-refresh-fail`

```mermaid
sequenceDiagram
    autonumber
    participant B as BFF
    participant R as Redis
    participant I as OIDC Provider

    B->>I: POST /token (grant_type=refresh_token)
    I-->>B: 400 invalid_grant
    B->>R: EVAL revoke_session.lua (sid, user_id, iss, idp_sid)
    B-->>B: clear cookie, return 401
```

#### Logout -- Local + RP-Initiated

**ID**: `cpt-insightspec-seq-bff-logout`

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant B as BFF
    participant R as Redis
    participant I as OIDC Provider

    U->>B: POST /auth/logout
    B->>R: EVAL revoke_session.lua<br/>DEL bff:session:{sid}<br/>ZREM bff:user_sessions:{uid} sid<br/>SREM bff:sid_index:{iss}:{idp_sid} sid<br/>DEL router:jwt_cache:{sid}
    R-->>B: OK
    B-->>U: 200 + Set-Cookie __Host-sid Max-Age=0 + {rp_logout_url}
    U->>I: GET end_session_endpoint?id_token_hint=...
    I-->>U: 302 back to SPA
```

#### Logout Everywhere

**ID**: `cpt-insightspec-seq-bff-logout-all`

**Use cases**: `cpt-insightspec-usecase-bff-logout-everywhere`

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant B as BFF
    participant R as Redis

    U->>B: DELETE /auth/sessions
    B->>R: ZRANGEBYSCORE bff:user_sessions:{uid} <now> +inf
    R-->>B: [sid1, sid2, sid3, ...]
    B->>R: EVAL revoke_user.lua<br/>DEL bff:session:{sid_1..N}<br/>DEL bff:user_sessions:{uid}<br/>DEL router:jwt_cache:{sid_1..N}
    R-->>B: count revoked
    B-->>U: 204 + Set-Cookie __Host-sid Max-Age=0
    Note over B: Within ≤300s all in-flight gateway JWTs expire.
```

#### Back-Channel Logout from IdP

**ID**: `cpt-insightspec-seq-bff-back-channel-logout`

```mermaid
sequenceDiagram
    autonumber
    participant I as OIDC Provider
    participant B as BFF
    participant R as Redis

    I->>B: POST /auth/oidc/back-channel-logout (logout_token)
    B->>B: validate logout_token (sig, iss, aud, iat, events, jti)
    B->>R: SMEMBERS bff:sid_index:{iss}:{idp_sid}
    R-->>B: [sid1, sid2, ...]
    B->>R: EVAL revoke_session.lua for each
    B-->>I: 200
```

### 3.7 Database schemas & tables

- [ ] `p3` - **ID**: `cpt-insightspec-db-bff-redis`

This module's "database" is Redis. The schema below describes the keyspace.

All BFF-owned keys carry the `bff:` prefix. The Router owns one prefix (`router:`) for its JWT cache; cross-references between the two are explicit.

```mermaid
graph LR
    USER[user_id]
    IDX["bff:user_sessions:{user_id}<br/>ZSET — score = expires_at"]
    S1["bff:session:{sid_1}<br/>HASH"]
    S2["bff:session:{sid_2}<br/>HASH"]
    SN["bff:session:{sid_n}<br/>HASH"]
    JC1["router:jwt_cache:{sid_1}<br/>STRING (signed JWT)"]
    JC2["router:jwt_cache:{sid_2}<br/>STRING"]
    SIDX["bff:sid_index:{iss}:{idp_sid}<br/>SET of session_id"]
    LS["bff:login_state:{state}<br/>HASH (5 min TTL)"]

    USER --> IDX
    IDX --> S1
    IDX --> S2
    IDX --> SN
    S1 -.Router caches.-> JC1
    S2 -.Router caches.-> JC2
    S1 -.idp sid lookup.-> SIDX
    S2 -.idp sid lookup.-> SIDX
```

#### Key: `bff:session:{session_id}`

**Type**: Redis HASH

| Field | Type | Description |
|---|---|---|
| `user_id` | String | Internal user identifier |
| `tenant_id` | String | Tenant the user logged into |
| `idp_iss` | String | OIDC issuer URL |
| `idp_sub` | String | OIDC subject |
| `idp_sid` | String | OIDC `sid` claim (for back-channel logout) |
| `access_token` | String | Encrypted IdP access token |
| `refresh_token` | String | Encrypted IdP refresh token |
| `access_expires_at` | Int (epoch s) | When IdP access token expires |
| `created_at` | Int (epoch s) | Session creation time |
| `expires_at` | Int (epoch s) | Current session expiry; advanced by `/auth/refresh` |
| `absolute_expires_at` | Int (epoch s) | Hard cap; cannot be extended past this |
| `user_agent` | String | Captured at login |
| `ip` | String | Captured at login |
| `csrf_token` | String | CSRF token bound to this session |

**Redis TTL**: matches `expires_at`. Re-set on every refresh.

#### Key: `bff:user_sessions:{user_id}`

**Type**: Redis ZSET

**Member**: `session_id`

**Score**: `expires_at` (epoch seconds)

**Why ZSET, not SET**:

- `ZRANGEBYSCORE bff:user_sessions:{uid} <now> +inf` returns active sessions (for `/auth/sessions`).
- `ZRANGEBYSCORE bff:user_sessions:{uid} 0 <now>` returns expired ones (for the janitor).
- `ZREMRANGEBYSCORE bff:user_sessions:{uid} 0 <now>` cleans them in one call.

**Maintenance**: Mutated atomically with `bff:session:*` via Lua scripts.

#### Key: `bff:sid_index:{iss}:{idp_sid}`

**Type**: Redis SET

**Members**: `session_id` strings

**Purpose**: Resolve OIDC back-channel `logout_token` (`iss` + `sid`) to local sessions. SET is sufficient -- no expiry-based queries needed; entries are removed on session revoke.

#### Key: `bff:login_state:{state}`

**Type**: Redis HASH

**Fields**: `pkce_verifier`, `nonce`, `redirect_to`

**TTL**: 5 minutes. One-shot -- deleted on callback.

#### Note on `router:jwt_cache:{session_id}`

Owned by the Router, not by the BFF. The BFF deletes these keys as part of revoke operations to invalidate cached gateway JWTs immediately. See [Router DESIGN §3.4](../router/DESIGN.md#34-redis-keys-read-only-and-jwt-cache).

### 3.8 Gateway JWT Claim Contract

- [ ] `p2` - **ID**: `cpt-insightspec-design-bff-jwt-claim-spec`

This section is the technical specification for the contract `cpt-insightspec-contract-bff-gateway-jwt` declared in [PRD §7.2](./PRD.md#72-external-integration-contracts). The BFF defines the contract; the Router mints; downstream services verify.

**Header**:

```json
{
  "alg": "EdDSA",
  "typ": "JWT",
  "kid": "<key id from JWKS>"
}
```

**Required JWT claims (RFC 7519)**:

| Claim | Type | Description |
|---|---|---|
| `iss` | String | `https://<gateway-host>/` |
| `aud` | String | `internal-services` |
| `sub` | String | Internal `user_id` |
| `iat` | Int | Issued at (epoch seconds) |
| `exp` | Int | `iat + 60..300` |
| `jti` | String | UUID v7 -- traceable, monotonic |

**Insight custom claims**:

| Claim | Type | Description |
|---|---|---|
| `tid` | String | `tenant_id` |
| `sid` | String | BFF session ID (opaque to downstream, used for tracing only) |

**Out of scope for v1**: `lic`, `roles`, `scopes`. Authorization is performed inside each downstream service against its own data sources. These claims may be added in a later major version of the contract.

**JWKS distribution**: each downstream service is configured (Helm value `gateway.jwks_url`, env `GATEWAY_JWKS_URL`) with the absolute URL of the gateway's JWKS endpoint. Services fetch on startup, cache for 1 h, and re-fetch on unknown `kid`. There is no service discovery; the URL is explicit.

**Verification at downstream**:

```mermaid
flowchart LR
    A[Receive JWT] --> B{Header parses?}
    B -- no --> R[401]
    B -- yes --> C{kid in JWKS cache?}
    C -- no --> D[Fetch GATEWAY_JWKS_URL]
    D --> E{kid found?}
    E -- no --> R
    E -- yes --> F
    C -- yes --> F[Verify EdDSA signature]
    F -- bad --> R
    F -- ok --> G{iss == gateway<br/>aud == internal-services?}
    G -- no --> R
    G -- yes --> H{exp > now?}
    H -- no --> R
    H -- yes --> I[Apply RBAC on sub + tid]
    I --> Z[200 / 403]
```

### 3.9 Boundary with the Router

| Concern | Owner | Notes |
|---|---|---|
| OIDC handshake | BFF | Router never talks to the IdP |
| Session create / refresh / revoke | BFF | Owns the Lua scripts |
| Cookie issue / clear | BFF | Router never sets cookies |
| CSRF token issue | BFF | Router enforces nothing CSRF-related on `/api/*` (relies on `SameSite=Strict`) |
| IdP access-token refresh | BFF | Triggered on `/auth/refresh` |
| Gateway JWT mint + sign | Router | Reads claims from session via shared session manager |
| JWKS publication | Router | Endpoint `/.well-known/jwks.json` |
| Reverse proxy `/api/*` | Router | Forwards with `Authorization: Bearer <jwt>` |
| Session manager library | BFF | Used by Router as a Rust crate |
| `bff:*` Redis keys | BFF | Router has read-only access to `bff:session:*` |
| `router:jwt_cache:*` Redis keys | Router | BFF deletes them as part of revoke |

## 4. Cross-Cutting Concerns

### 4.1 Cookie Hardening

A single helper sets every session cookie. Attributes are hard-coded in code, only `Max-Age` is from config:

- Name: `__Host-sid` (forces Secure + Path=/ + no Domain).
- `HttpOnly`.
- `Secure`.
- `SameSite=Strict`.
- `Path=/`.
- `Max-Age` = configured `session_ttl` (default 120 s) or `0` for clears.

A unit test asserts the exact `Set-Cookie` header for set and clear cases. Any other code path setting cookies fails review.

### 4.2 CSRF Defense

Primary: `SameSite=Strict`.

Secondary, on POST/PUT/PATCH/DELETE on `/auth/*`:

1. Read `X-CSRF-Token` header.
2. Compare against `session.csrf_token` (constant-time).
3. If absent or mismatched, check `Origin` against the configured SPA origin allowlist.
4. If both fail, return 403.

The CSRF token is rotated on login. The SPA fetches it once via `GET /auth/csrf` after login.

### 4.3 Janitor for Expired Sessions

A background task on every BFF pod (one elected leader via Redis lock) runs every `janitor_interval` seconds (default 30 s):

1. `SCAN MATCH bff:user_sessions:*` to enumerate user index keys.
2. For each, `ZREMRANGEBYSCORE key 0 <now>` to drop expired entries.
3. Emit `bff_janitor_removed_total` metric and `bff_janitor_backlog_size` (entries removed in last pass).

Per-session Redis TTL on `bff:session:{id}` already removes the record itself. The janitor exists only to keep the index clean so `/auth/sessions` and revoke-all stay fast.

```mermaid
flowchart LR
    T[Tick] --> L{Acquire<br/>Redis lock?}
    L -- no --> Skip[Skip pass]
    L -- yes --> Scan[SCAN bff:user_sessions:*]
    Scan --> Loop{For each key}
    Loop --> Trim[ZREMRANGEBYSCORE 0 now]
    Trim --> Metric[Emit metric]
    Metric --> Loop
    Loop --> Done[Release lock]
```

### 4.4 Observability

Metrics (Prometheus):

- `bff_auth_login_total{result}` -- ok / fail / state_mismatch
- `bff_auth_refresh_total{result}` -- ok / expired / past_cap / idp_fail
- `bff_session_active` -- gauge from periodic Redis sample
- `bff_session_lookup_duration_seconds` -- histogram
- `bff_idp_refresh_total{result}` -- ok / fail
- `bff_back_channel_logout_total{result}`
- `bff_janitor_removed_total`
- `bff_janitor_backlog_size`

Logs (structured JSON): every auth event with `correlation_id`, `session_id` (hashed), `user_id`, `tenant_id`. Never log cookies, raw tokens, or refresh tokens.

Audit (via Audit Service): login OK, login fail, refresh, logout, revoke (single / all / admin), back-channel logout, IdP refresh failure.

## 5. Design Decisions

### DD-BFF-01: Opaque Session vs JWT Cookie

**Decision**: Opaque session ID + Redis lookup, not a cookie-borne JWT.

**Why**:
- Revocation must be instant (offboarding, suspected compromise) -- only possible with a server-side store.
- Opaque IDs leak less on theft -- they only work on this host, not as a portable bearer.
- Cookie size stays tiny.

**Consequences**: Hard dependency on Redis. No local cache, no degraded mode (see DD-BFF-06).

### DD-BFF-02: Explicit Session Refresh, No Sliding TTL

**Decision**: Session TTL is short and hard. Only `POST /auth/refresh` extends it.

**Why**:
- Sliding TTL on every API call requires a Redis write on the hot path. Explicit refresh moves writes off the hot path.
- The SPA already knows when the user is active; making refresh explicit gives it control and keeps the BFF predictable.
- Hard TTL bounds the window for stolen-cookie reuse.

**Consequences**: SPA must implement a refresh loop. Documented as part of the SPA contract; the BFF returns 401 on expiry, and the SPA redirects to `/auth/login`.

### DD-BFF-03: ZSET (Not SET) for User-Session Index

**Decision**: `bff:user_sessions:{user_id}` is a Redis sorted set with score = `expires_at`.

**Why**:
- Plain SET cannot answer "which of these sessions are expired" without reading every member's record.
- ZSET makes both "active sessions" and "expired entries" O(log N) lookups via `ZRANGEBYSCORE`.
- Janitor cleanup is a single `ZREMRANGEBYSCORE` per user.

**Consequences**: Slightly more Redis memory per entry (score + element vs element only). Negligible at our scale.

### DD-BFF-04: BFF-Prefixed Redis Keys

**Decision**: Every Redis key owned by the BFF starts with `bff:`. Router uses `router:`. Future modules pick their own prefix.

**Why**:
- Single Redis instance is shared across modules. Owner-prefixed names eliminate collisions.
- Operators reading Redis keys can identify the owner from the prefix.
- Migration of one module's data is a single prefix scan.

**Consequences**: Slightly longer keys. Worth it.

### DD-BFF-05: EdDSA Algorithm for Gateway JWT Contract

**Decision**: The gateway JWT contract mandates EdDSA (Ed25519). No other algorithms.

**Why**:
- Small signatures (~64 bytes) keep header size down.
- Fast verification (~10× faster than RS256).
- Single private/public key pair, no padding choices.

**Consequences**: Verifier libraries in downstream services must support EdDSA. Documented as a constraint on adding new downstream services.

### DD-BFF-06: Redis Outage = No Auth (Fail Closed)

**Decision**: When Redis is unreachable, the BFF returns 401 on `/auth/*` mutations and 503 on the readiness probe. There is no local in-memory session cache and no degraded read-only mode.

**Why**:
- A local cache is expensive to keep coherent across pods -- a revoke on pod A would have to invalidate the cache on every other pod.
- Coherent session state is the whole reason we keep sessions in Redis. A "best-effort" local cache contradicts that.
- The Router also fails closed on Redis loss, so a degraded mode in the BFF would not actually let users do anything useful.

**Consequences**: Redis availability is the auth availability. HA Redis is mandatory in the production Helm values; documented in the operator runbook.

### DD-BFF-07: `/auth/refresh` Returns Next-Refresh Deadline

**Decision**: `POST /auth/refresh` returns `200` with a JSON body:

```json
{
  "expires_at": 1714320120,
  "refresh_at": 1714320060
}
```

`expires_at` is the absolute moment the session will expire if not refreshed again. `refresh_at` is the recommended next-refresh moment (`expires_at - safety_margin`, default `safety_margin` = 30 s, configurable).

**Why**:
- The SPA needs to know when to call refresh next; computing it client-side from `Max-Age` plus a hard-coded fudge factor is fragile and silently goes wrong if the operator changes `session_ttl`.
- A server-supplied deadline lets the operator tune the cadence without an SPA change.

**Consequences**: SPA implements a single timer `setTimeout(refresh, refresh_at - now)`. On 401, it redirects to `/auth/login`. The same body is returned by `/auth/me` so the SPA can prime the timer at startup.

### DD-BFF-08: `SameSite=Strict` Today, Pluggable Cookie Classes Later

**Decision**: The session cookie stays `SameSite=Strict` for v1. We accept the deep-link drawback (external links land users on the login page).

**Why**:
- Strict gives the strongest CSRF baseline.
- Mixing a Lax companion cookie now would complicate revoke / refresh logic for marginal UX gain at this stage.

**Future**: When we have a real need (e.g. shareable dashboard links, embedded views, or a public read-only token class), we'll introduce a second cookie class with its own attributes and lifecycle, kept separate from the primary session.

### DD-BFF-09: Janitor Coordinates via Redis Lock

**Decision**: A single distributed Redis lock (`bff:lock:janitor`, TTL slightly longer than the pass interval) elects one pod per pass. No external CronJob.

**Why**:
- One process inside the BFF binary keeps deployment simple -- no extra K8s object to manage or version.
- Redis is already a hard dependency; reusing it for coordination adds no new failure mode.
- Pass interval (default 30 s) is short enough that a missed pass costs little.

**Consequences**: Pod with the lock takes the work; others skip. Backlog metric alerts if no pod runs the pass for more than `2 × interval`.

## 6. Traceability

- **PRD**: [PRD.md](./PRD.md)
- **Sibling**: [Router PRD](../router/PRD.md), [Router DESIGN](../router/DESIGN.md) -- gateway JWT minting, JWKS, `/api/*` proxy, route config
- **Parent**: [API Gateway PRD](../PRD.md), [API Gateway DESIGN](../DESIGN.md) -- umbrella docs
- **Backend**: [Backend PRD](../../specs/PRD.md), [Backend DESIGN](../../specs/DESIGN.md)
- **ADRs**: [ADR/](./ADR/) -- to be authored alongside implementation. Decisions captured inline as DD-BFF-01..09 in §5 until then.

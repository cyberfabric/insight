-- Identity Resolution: operator link table.
-- Other identity tables (input VIEW, proposals, person) are managed by dbt.
-- Prerequisite: identity database created by 20260408000000_init-identity.sql

-- ============================================================
-- identity.links — operator decisions: profile <-> person bindings
-- Append-only. Each row = "at time X, profile Y was linked/unlinked to person Z"
-- profile_id is always set (even on unlink) to preserve which profile was affected.
-- action column distinguishes link from unlink.
-- ============================================================

CREATE TABLE IF NOT EXISTS identity.links
(
    id                  UUID DEFAULT generateUUIDv7(),
    insight_tenant_id   String,
    person_id           UUID,
    source_type         LowCardinality(String),
    profile_id          String,                            -- always set, even on unlink
    action              LowCardinality(String) DEFAULT 'link',  -- link, unlink
    reason              String DEFAULT '',                  -- new_person, merge, split, same_email, operator_decision
    created_by          String DEFAULT '',
    created_at          DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = MergeTree
ORDER BY (insight_tenant_id, source_type, profile_id, created_at);
-- Primary lookup: "which person is this profile linked to?" → filter by source_type + profile_id

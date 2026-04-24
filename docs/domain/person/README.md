# Person Domain

The Person domain owns the canonical person record — the single source of truth for who each person is, what their attributes are, and which source contributed each attribute. It assembles golden records from multiple source contributions using configurable source-priority rules.

## Documents

| Document | Description |
|---|---|
| [`specs/PRD.md`](specs/PRD.md) | Product requirements: golden record assembly, conflict detection, availability tracking, status management |
| [`specs/DESIGN.md`](specs/DESIGN.md) | Technical design: persons table (merged entity), GoldenRecordBuilder, ConflictDetector, source contributions, availability |

## Scope

This domain covers:
- `persons` table — canonical person records with inlined golden record fields
- Golden record assembly from multiple source contributions (per-attribute source priority)
- Person-attribute conflict detection and operator resolution workflow
- Person availability tracking (leave/capacity periods)
- Person status management (`active`, `inactive`, `external`, `bot`)
- Per-attribute source provenance (`*_source` columns on `persons`)
- Completeness scoring
- History via SCD Type 2 / SCD Type 3 (dbt macros, out of scope for table schema)

Out of scope:
- Alias-to-person resolution (`aliases`, `match_rules`, `unmapped`) — see [`docs/domain/identity-resolution/`](../identity-resolution/)
- Org hierarchy (`org_units`, `person_assignments`) — see [`docs/domain/org-chart/`](../org-chart/)
- SCD Type 2/3 snapshot table schemas — managed by dbt macros
- Permission / RBAC
- Connector implementation

## Cross-Domain References

- **Identity Resolution domain**: `aliases.person_id` references `persons.id`. IR resolves aliases to person records owned by this domain. The shared `identity_inputs` table (owned by IR) provides person-attribute observations that feed golden record assembly.
- **Org-Chart domain**: `persons.org_unit_id` references `org_units.id`. The Org-Chart domain owns the org hierarchy; this domain stores the current org unit assignment as a golden record field. `person_assignments.person_id` references `persons.id`.

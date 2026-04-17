{% macro identity_input_from_history(
    fields_history_ref,
    source_type,
    identity_fields,
    deactivation_condition
) %}
{#
  Generates identity.input rows from a fields_history model.
  Produces UPSERT rows for identity-relevant field changes, and DELETE rows
  for all identity fields when a deactivation condition is met.

  Designed for incremental models: when is_incremental() is true, only
  processes fields_history rows newer than the last observed_at in the target.

  Args:
    fields_history_ref:     ref() to the fields_history model
    source_type:            source system name (e.g., 'bamboohr', 'zoom')
    identity_fields:        list of dicts with keys:
                              - field: source field name in fields_history (e.g., 'workEmail')
                              - field_type: identity field type (e.g., 'email')
                              - field_path: fully-qualified field path
                                (e.g., 'bronze_bamboohr.employees.workEmail')
    deactivation_condition: SQL expression evaluated against fields_history row
                            that returns true when the entity is deactivated.
                            Available columns: entity_id, tenant_id, source_id,
                            field_name, old_value, new_value, updated_at.
                            Example: "field_name = 'status' AND new_value = 'Inactive'"

  Output columns (match identity.input schema):
    insight_tenant_id, source_type, source_id, profile_id,
    field_type, field_value, field_path, operation, observed_at, _synced_at
#}

WITH history AS (
    SELECT *
    FROM {{ fields_history_ref }}
    {% if is_incremental() %}
    WHERE updated_at > (SELECT coalesce(max(observed_at), toDateTime64('1970-01-01', 3, 'UTC')) FROM {{ this }})
    {% endif %}
),

-- UPSERT: identity field changed
upserts AS (
    {% for f in identity_fields %}
    SELECT
        coalesce(tenant_id, '') AS insight_tenant_id,
        '{{ source_type }}' AS source_type,
        coalesce(source_id, '') AS source_id,
        entity_id AS profile_id,
        '{{ f.field_type }}' AS field_type,
        coalesce(new_value, '') AS field_value,
        '{{ f.field_path }}' AS field_path,
        -- empty new_value = field was cleared (tombstone), non-empty = field changed
        if(coalesce(new_value, '') = '', 'DELETE', 'UPSERT') AS operation,
        updated_at AS observed_at,
        now64(3) AS _synced_at
    FROM history
    WHERE field_name = '{{ f.field }}'
    {{ 'UNION ALL' if not loop.last }}
    {% endfor %}
),

-- DELETE: deactivation detected — emit DELETE for all identity fields
deactivation_events AS (
    SELECT
        tenant_id,
        source_id,
        entity_id,
        updated_at
    FROM history
    WHERE {{ deactivation_condition }}
),

deletes AS (
    {% for f in identity_fields %}
    SELECT
        coalesce(d.tenant_id, '') AS insight_tenant_id,
        '{{ source_type }}' AS source_type,
        coalesce(d.source_id, '') AS source_id,
        d.entity_id AS profile_id,
        '{{ f.field_type }}' AS field_type,
        '' AS field_value,
        '{{ f.field_path }}' AS field_path,
        'DELETE' AS operation,
        d.updated_at AS observed_at,
        now64(3) AS _synced_at
    FROM deactivation_events d
    {{ 'UNION ALL' if not loop.last }}
    {% endfor %}
)

SELECT * FROM upserts
UNION ALL
SELECT * FROM deletes

{% endmacro %}

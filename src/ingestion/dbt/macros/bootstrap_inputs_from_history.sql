{% macro bootstrap_inputs_from_history(
    fields_history_ref,
    source_type,
    identity_fields,
    deactivation_condition
) %}
{#
  Generates bootstrap_inputs rows from a fields_history model.
  Produces UPSERT rows for identity-relevant field changes, and DELETE rows
  for all identity fields when a deactivation condition is met.

  Designed for incremental models: when is_incremental() is true, only
  processes fields_history rows newer than the last _synced_at in the target.

  Args:
    fields_history_ref:     ref() to the fields_history model
    source_type:            insight_source_type value (e.g., 'bamboohr', 'zoom')
    identity_fields:        list of dicts with keys:
                              - field: source field name in fields_history (e.g., 'workEmail')
                              - alias_type: bootstrap alias type (e.g., 'email')
                              - alias_field_name: fully-qualified field path
                                (e.g., 'bronze_bamboohr.employees.workEmail')
    deactivation_condition: SQL expression evaluated against fields_history row
                            that returns true when the entity is deactivated.
                            Available columns: entity_id, tenant_id, source_id,
                            field_name, old_value, new_value, updated_at.
                            Example: "field_name = 'status' AND new_value = 'Inactive'"

  Output columns (match bootstrap_inputs schema):
    insight_tenant_id, insight_source_id, insight_source_type, source_account_id,
    alias_type, alias_value, alias_field_name, operation_type, _synced_at
#}

WITH history AS (
    SELECT *
    FROM {{ fields_history_ref }}
    {% if is_incremental() %}
    WHERE updated_at > (SELECT max(_synced_at) FROM {{ this }})
    {% endif %}
),

-- UPSERT: identity field changed
upserts AS (
    {% for f in identity_fields %}
    SELECT
        tenant_id AS insight_tenant_id,
        source_id AS insight_source_id,
        '{{ source_type }}' AS insight_source_type,
        entity_id AS source_account_id,
        '{{ f.alias_type }}' AS alias_type,
        new_value AS alias_value,
        '{{ f.alias_field_name }}' AS alias_field_name,
        'UPSERT' AS operation_type,
        updated_at AS _synced_at
    FROM history
    WHERE field_name = '{{ f.field }}'
      AND new_value != ''
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
        d.tenant_id AS insight_tenant_id,
        d.source_id AS insight_source_id,
        '{{ source_type }}' AS insight_source_type,
        d.entity_id AS source_account_id,
        '{{ f.alias_type }}' AS alias_type,
        '' AS alias_value,
        '{{ f.alias_field_name }}' AS alias_field_name,
        'DELETE' AS operation_type,
        d.updated_at AS _synced_at
    FROM deactivation_events d
    {{ 'UNION ALL' if not loop.last }}
    {% endfor %}
)

SELECT * FROM upserts
UNION ALL
SELECT * FROM deletes

{% endmacro %}

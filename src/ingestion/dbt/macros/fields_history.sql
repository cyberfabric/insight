{% macro fields_history(snapshot_ref, entity_id_col, fields) %}
{#
  Generates a field-level change log from a snapshot model.
  One row per changed field per version transition.

  Args:
    snapshot_ref:   ref() to the snapshot incremental model
    entity_id_col:  column name for the entity identifier
    fields:         list of column names to track

  Output columns:
    entity_id, tenant_id, source_id, field_name, old_value, new_value, updated_at
#}

WITH versioned AS (
    SELECT
        unique_key,
        {{ entity_id_col }} AS entity_id,
        tenant_id,
        source_id,
        {% for f in fields %}
        toString({{ f }}) AS {{ f }},
        {% endfor %}
        _tracked_at AS updated_at,
        ROW_NUMBER() OVER (
            PARTITION BY unique_key ORDER BY _tracked_at
        ) AS version_num
    FROM {{ snapshot_ref }}
),

consecutive AS (
    SELECT
        curr.entity_id,
        curr.tenant_id,
        curr.source_id,
        curr.updated_at,
        {% for f in fields %}
        curr.{{ f }} AS curr_{{ f }},
        prev.{{ f }} AS prev_{{ f }}{{ ',' if not loop.last }}
        {% endfor %}
    FROM versioned curr
    INNER JOIN versioned prev
        ON curr.unique_key = prev.unique_key
        AND curr.version_num = prev.version_num + 1
)

{% for f in fields %}
SELECT
    entity_id, tenant_id, source_id,
    '{{ f }}' AS field_name,
    prev_{{ f }} AS old_value,
    curr_{{ f }} AS new_value,
    updated_at
FROM consecutive
WHERE curr_{{ f }} != prev_{{ f }}
{{ 'UNION ALL' if not loop.last }}
{% endfor %}

{% endmacro %}

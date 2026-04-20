{% macro skip_if_no_source(db_name) %}
  {%- set dbs = var('available_dbs', none) -%}
  {%- if dbs is not none and db_name not in dbs -%}
    {{ log(model.name ~ ": skipping — " ~ db_name ~ " not available", info=True) }}
    {{ config(materialized='ephemeral') }}
  {%- endif -%}
{% endmacro %}

{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

-- explicit dependency so dbt knows to run staging models first
-- depends_on: {{ ref('m365__collab_email_activity') }}

{{ union_by_tag('silver:class_collab_email_activity') }}

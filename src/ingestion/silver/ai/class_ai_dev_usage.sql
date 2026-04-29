{{ config(
    materialized='view',
    schema='silver',
    tags=['silver']
) }}

-- depends_on: {{ ref('cursor__ai_dev_usage') }}
-- depends_on: {{ ref('claude_enterprise__ai_dev_usage') }}

{{ union_by_tag('silver:class_ai_dev_usage') }}

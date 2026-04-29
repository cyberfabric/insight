{{ config(
    materialized='view',
    schema='silver',
    tags=['silver']
) }}

-- depends_on: {{ ref('claude_admin__ai_api_usage') }}
-- depends_on: {{ ref('claude_enterprise__ai_api_usage') }}

{{ union_by_tag('silver:class_ai_api_usage') }}

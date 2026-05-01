{{ config(
    materialized='view',
    schema='silver',
    tags=['silver']
) }}

-- depends_on: {{ ref('claude_enterprise__ai_assistant_usage') }}

{{ union_by_tag('silver:class_ai_assistant_usage') }}

{{ config(
    materialized='view',
    tags=['silver']
) }}

-- depends_on: {{ ref('to_crm_deals') }}

{{ union_by_tag('silver:class_crm_deals') }}

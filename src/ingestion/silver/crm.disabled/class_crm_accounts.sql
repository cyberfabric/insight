{{ config(
    materialized='view',
    tags=['silver']
) }}

-- depends_on: {{ ref('to_crm_accounts') }}

{{ union_by_tag('silver:class_crm_accounts') }}

{{ config(
    materialized='view',
    tags=['silver']
) }}

-- depends_on: {{ ref('to_crm_contacts') }}

{{ union_by_tag('silver:class_crm_contacts') }}

{{ config(
    materialized='view',
    tags=['silver']
) }}

-- depends_on: {{ ref('bamboohr__bootstrap_inputs') }}
-- depends_on: {{ ref('zoom__bootstrap_inputs') }}

{{ union_by_tag('silver:bootstrap_inputs') }}

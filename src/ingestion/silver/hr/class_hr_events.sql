{{ config(
    materialized='view',
    schema='silver',
    tags=['silver']
) }}

-- depends_on: {{ ref('bamboohr__hr_events') }}

{{ union_by_tag('silver:class_hr_events') }}

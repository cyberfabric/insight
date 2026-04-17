{{ config(
    materialized='view',
    schema='silver',
    tags=['silver']
) }}

-- depends_on: {{ ref('bamboohr__working_hours') }}

{{ union_by_tag('silver:class_hr_working_hours') }}

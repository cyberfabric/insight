{{ config(
    materialized='view',
    tags=['silver']
) }}

-- depends_on: {{ ref('to_class_people') }}

{{ union_by_tag('silver:class_people') }}

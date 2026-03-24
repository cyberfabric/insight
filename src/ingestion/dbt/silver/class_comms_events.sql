{{ config(
    materialized='view',
    tags=['silver']
) }}

-- depends_on: {{ ref('to_comms_events') }}

{{ union_by_tag('silver:class_comms_events') }}

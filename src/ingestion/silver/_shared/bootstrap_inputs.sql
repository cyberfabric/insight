{{ config(
    materialized='view',
    schema='identity',
    tags=['silver']
) }}

-- depends_on: {{ ref('bamboohr__bootstrap_inputs') }}
-- depends_on: {{ ref('zoom__bootstrap_inputs') }}
-- depends_on: {{ ref('seed_bootstrap_inputs_from_cursor') }}
-- depends_on: {{ ref('seed_bootstrap_inputs_from_claude_team') }}

{{ union_by_tag('silver:bootstrap_inputs') }}

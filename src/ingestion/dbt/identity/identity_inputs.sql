{{ config(
    materialized='view',
    schema='identity',
    tags=['identity']
) }}

-- Unified identity inputs from all connectors.
-- Source models tagged 'identity:input':
--   bamboohr__identity_input, zoom__identity_input,
--   seed_identity_input_from_cursor, seed_identity_input_from_claude_admin
--
-- depends_on: {{ ref('bamboohr__identity_input') }}
-- depends_on: {{ ref('zoom__identity_input') }}
-- depends_on: {{ ref('seed_identity_input_from_cursor') }}
-- depends_on: {{ ref('seed_identity_input_from_claude_admin') }}

{{ union_by_tag('identity:input') }}

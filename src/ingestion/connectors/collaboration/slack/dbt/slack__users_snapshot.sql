{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['slack']
) }}

{{ snapshot(
    source_ref=source('bronze_slack', 'users'),
    unique_key_col='unique_key',
    check_cols=[
        'email', 'display_name', 'real_name',
        'is_admin', 'is_owner', 'is_restricted', 'is_ultra_restricted',
        'is_bot', 'deleted', 'tz'
    ]
) }}

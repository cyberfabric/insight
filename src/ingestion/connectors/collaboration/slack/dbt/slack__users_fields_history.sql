{{ config(
    materialized='table',
    schema='staging',
    tags=['slack', 'silver']
) }}

{{ fields_history(
    snapshot_ref=ref('slack__users_snapshot'),
    entity_id_col='unique_key',
    fields=[
        'email', 'display_name', 'real_name',
        'is_admin', 'is_owner', 'is_restricted', 'is_ultra_restricted',
        'is_bot', 'deleted', 'tz'
    ]
) }}

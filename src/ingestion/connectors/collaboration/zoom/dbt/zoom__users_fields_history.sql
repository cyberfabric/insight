{{ config(
    materialized='table',
    schema='staging',
    tags=['zoom', 'silver']
) }}

{{ skip_if_no_source("bronze_zoom") }}

{{ fields_history(
    snapshot_ref=ref('zoom__users_snapshot'),
    entity_id_col='id',
    fields=[
        'first_name', 'last_name', 'display_name', 'email',
        'dept', 'status', 'role_id', 'timezone', 'language',
        'phone_number', 'employee_unique_id', 'type'
    ]
) }}

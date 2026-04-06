{{ config(
    materialized='table',
    schema='staging',
    tags=['zoom', 'silver']
) }}

{{ fields_history(
    snapshot_ref=ref('zoom__users_snapshot'),
    entity_id_col='id',
    fields=[
        'first_name', 'last_name', 'display_name', 'email',
        'dept', 'status', 'role_id', 'timezone', 'language',
        'phone_number', 'employee_unique_id', 'type'
    ]
) }}

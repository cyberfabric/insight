{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['zoom', 'silver', 'silver:bootstrap_inputs']
) }}

{{ bootstrap_inputs_from_history(
    fields_history_ref=ref('zoom__users_fields_history'),
    source_type='zoom',
    identity_fields=[
        {'field': 'email', 'alias_type': 'email', 'alias_field_name': 'bronze_zoom.users.email'},
        {'field': 'employee_unique_id', 'alias_type': 'employee_id', 'alias_field_name': 'bronze_zoom.users.employee_unique_id'},
        {'field': 'display_name', 'alias_type': 'display_name', 'alias_field_name': 'bronze_zoom.users.display_name'},
    ],
    deactivation_condition="field_name = 'status' AND new_value = 'inactive'"
) }}

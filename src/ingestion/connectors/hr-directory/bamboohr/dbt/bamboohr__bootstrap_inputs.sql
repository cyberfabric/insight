{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['bamboohr', 'silver', 'silver:bootstrap_inputs']
) }}

{{ bootstrap_inputs_from_history(
    fields_history_ref=ref('bamboohr__employees_fields_history'),
    source_type='bamboohr',
    identity_fields=[
        {'field': 'workEmail', 'alias_type': 'email', 'alias_field_name': 'bronze_bamboohr.employees.workEmail'},
        {'field': 'employeeNumber', 'alias_type': 'employee_id', 'alias_field_name': 'bronze_bamboohr.employees.employeeNumber'},
        {'field': 'displayName', 'alias_type': 'display_name', 'alias_field_name': 'bronze_bamboohr.employees.displayName'},
    ],
    deactivation_condition="field_name = 'status' AND new_value IN ('Inactive', 'Terminated')"
) }}

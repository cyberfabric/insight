{{ config(
    materialized='table',
    schema='staging',
    tags=['bamboohr', 'silver']
) }}

{{ skip_if_no_source("bronze_bamboohr") }}

{{ fields_history(
    snapshot_ref=ref('bamboohr__employees_snapshot'),
    entity_id_col='id',
    fields=[
        'displayName', 'firstName', 'lastName', 'workEmail',
        'employeeNumber', 'jobTitle', 'department', 'division',
        'status', 'employmentHistoryStatus',
        'supervisorEId', 'supervisorEmail',
        'location', 'country', 'city',
        'hireDate', 'terminationDate'
    ],
    fields_raw_data=var('bamboohr_custom_fields', [])
) }}

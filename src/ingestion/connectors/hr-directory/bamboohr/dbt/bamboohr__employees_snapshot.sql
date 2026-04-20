{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['bamboohr']
) }}

{{ skip_if_no_source("bronze_bamboohr") }}

{{ snapshot(
    source_ref=source('bamboohr', 'employees'),
    unique_key_col='unique_key',
    check_cols=[
        'displayName', 'firstName', 'lastName', 'workEmail',
        'employeeNumber', 'jobTitle', 'department', 'division',
        'status', 'employmentHistoryStatus',
        'supervisorEId', 'supervisorEmail',
        'location', 'country', 'city',
        'hireDate', 'terminationDate'
    ],
    check_raw_data_cols=var('bamboohr_custom_fields', [])
) }}

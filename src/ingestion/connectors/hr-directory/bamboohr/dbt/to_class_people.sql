-- Bronze → Silver step 1: BambooHR Employees → class_people
-- Full-refresh source. Maps employee records to unified person registry.
-- SCD Type 2: valid_from = lastChanged, valid_to = NULL (current-state snapshot).
-- Full SCD history tracking is handled downstream.
{{ config(
    materialized='view',
    schema='bamboohr',
    tags=['silver:class_people']
) }}

SELECT
    coalesce(tenant_id, '')                         AS workspace_id,
    -- person_id resolved in Silver Step 2 via Identity Manager
    NULL                                            AS person_id,
    lastChanged                                     AS valid_from,
    CAST(NULL AS Nullable(DateTime))                AS valid_to,
    'bamboohr'                                      AS source,
    id                                              AS source_person_id,
    employeeNumber                                  AS employee_number,
    displayName                                     AS display_name,
    firstName                                       AS first_name,
    lastName                                        AS last_name,
    workEmail                                       AS email,
    jobTitle                                        AS job_title,
    department                                      AS department_name,
    NULL                                            AS org_unit_id,
    supervisorEId                                   AS manager_person_id,
    CASE
        WHEN status = 'Active' THEN 'active'
        WHEN employmentHistoryStatus = 'Terminated' THEN 'terminated'
        ELSE 'active'
    END                                             AS status,
    CASE
        WHEN standardHoursPerWeek IS NOT NULL
             AND toFloat64OrNull(standardHoursPerWeek) < 40
        THEN 'part_time'
        ELSE 'full_time'
    END                                             AS employment_type,
    parseDateTimeBestEffortOrNull(hireDate)          AS hire_date,
    parseDateTimeBestEffortOrNull(terminationDate)   AS termination_date,
    location                                        AS location,
    country                                         AS country,
    CASE
        WHEN standardHoursPerWeek IS NOT NULL
        THEN toFloat64OrNull(standardHoursPerWeek) / 40.0
        ELSE NULL
    END                                             AS fte,
    CAST(map('division', coalesce(division, '')) AS Map(String, String))
                                                    AS custom_str_attrs,
    CAST(map() AS Map(String, Float64))             AS custom_num_attrs,
    _airbyte_extracted_at                           AS ingested_at
FROM {{ source('bamboohr', 'employees') }}

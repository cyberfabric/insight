{{ config(
    materialized='view',
    alias='jira__task_field_history_tagged',
    schema='staging',
    tags=['jira', 'silver:class_task_field_history']
) }}

-- Rust `jira-enrich` writes to `staging.jira__task_field_history` directly — that table's
-- DDL is managed by the `create_task_field_history_staging` macro (see `on-run-start` in
-- `dbt_project.yml`) and invariants are enforced by the Rust INSERT path. This view just
-- exposes that table to the dbt graph under the `silver:class_task_field_history` tag so
-- the downstream `class_task_field_history` silver model can union it via `union_by_tag`.
--
-- Alias deliberately differs (`_tagged`) to avoid a name collision with the staging table
-- that Rust owns.

SELECT *
FROM {{ source('staging_jira', 'jira__task_field_history') }}

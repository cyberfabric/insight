-- SCD2 snapshot of cursor team members
-- Appends a new row only when name, role, or isRemoved changes
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['cursor']
) }}

{{ snapshot(
    source_ref=source('bronze_cursor', 'cursor_members'),
    unique_key_col='unique_key',
    check_cols=['name', 'role', 'isRemoved']
) }}

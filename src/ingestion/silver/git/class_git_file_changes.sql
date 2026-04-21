-- depends_on: {{ ref('github__file_changes') }}
-- depends_on: {{ ref('bitbucket_cloud__file_changes') }}
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

{{ union_by_tag('silver:class_git_file_changes') }}

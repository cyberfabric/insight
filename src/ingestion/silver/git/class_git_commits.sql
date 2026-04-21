-- depends_on: {{ ref('github__commits') }}
-- depends_on: {{ ref('bitbucket_cloud__commits') }}
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

{{ union_by_tag('silver:class_git_commits') }}

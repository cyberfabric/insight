-- depends_on: {{ ref('github__pull_requests_commits') }}
-- depends_on: {{ ref('bitbucket_cloud__pull_requests_commits') }}
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

{{ union_by_tag('silver:class_git_pull_requests_commits') }}

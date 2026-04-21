-- depends_on: {{ ref('github__repositories') }}
-- depends_on: {{ ref('bitbucket_cloud__repositories') }}
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

{{ union_by_tag('silver:class_git_repositories') }}

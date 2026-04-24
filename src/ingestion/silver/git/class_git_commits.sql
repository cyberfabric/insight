-- depends_on: {{ ref('github__commits') }}
-- depends_on: {{ ref('bitbucket_cloud__commits') }}
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    incremental_strategy='append',
    order_by=['unique_key'],
    schema='silver',
    tags=['silver']
) }}

SELECT * FROM (
    {{ union_by_tag('silver:class_git_commits') }}
)
{% if is_incremental() %}
WHERE _version > (SELECT max(_version) FROM {{ this }})
{% endif %}

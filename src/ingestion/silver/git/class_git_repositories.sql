-- depends_on: {{ ref('github__repositories') }}
-- depends_on: {{ ref('bitbucket_cloud__repositories') }}
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    incremental_strategy='append',
    order_by=['unique_key'],
    schema='silver',
    tags=['silver']
) }}

SELECT * FROM (
    {{ union_by_tag('silver:class_git_repositories') }}
)
{% if is_incremental() %}
WHERE _version > (SELECT max(_version) FROM {{ this }})
{% endif %}

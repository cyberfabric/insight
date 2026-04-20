{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['bitbucket-cloud', 'silver:class_git_repository_branches']
) }}

{{ skip_if_no_source("bronze_bitbucket_cloud") }}

SELECT
    tenant_id,
    source_id,
    unique_key,
    COALESCE(workspace, '') AS project_key,
    COALESCE(repo_slug, '') AS repo_slug,
    COALESCE(name, '') AS branch_name,
    if(name = mainbranch_name, 1, 0) AS is_default,
    COALESCE(JSONExtractString(target, 'hash'), '') AS last_commit_hash,
    parseDateTimeBestEffortOrNull(updated_on) AS last_commit_date,
    'insight_bitbucket_cloud' AS data_source,
    toUnixTimestamp64Milli(now64()) AS _version,
    _airbyte_extracted_at
FROM {{ source('bronze_bitbucket_cloud', 'branches') }}
{% if is_incremental() %}
WHERE _airbyte_extracted_at > (SELECT max(_airbyte_extracted_at) FROM {{ this }})
{% endif %}

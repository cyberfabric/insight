{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

-- explicit dependency so dbt knows to run staging models first
-- depends_on: {{ ref('m365__collab_document_activity_onedrive') }}
-- depends_on: {{ ref('m365__collab_document_activity_sharepoint') }}

{{ union_by_tag('silver:class_collab_document_activity') }}

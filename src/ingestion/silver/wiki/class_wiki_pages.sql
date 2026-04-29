{{ config(
    materialized='view',
    schema='silver',
    tags=['silver']
) }}

-- depends_on: {{ ref('confluence__wiki_pages') }}

{{ union_by_tag('silver:class_wiki_pages') }}

{{ config(
    materialized='table',
    schema='silver',
    tags=['silver']
) }}

-- reviews_given intentionally excluded: fct_git_review.person_key lives in
-- the reviewer-login namespace (GitHub login, Bitbucket display_name), which
-- does not match the email-based person_key used by commits/PRs. Returns
-- once identity resolution bridges the two namespaces.

WITH prs AS (
    SELECT
        tenant_id,
        person_key,
        count()                                                AS prs_created,
        countIf(state_norm = 'merged')                         AS prs_merged,
        avgIf(cycle_time_h, cycle_time_h IS NOT NULL)          AS avg_pr_cycle_time_h
    FROM {{ ref('fct_git_pr') }}
    WHERE person_key != ''
    GROUP BY tenant_id, person_key
),
commits AS (
    SELECT
        tenant_id,
        person_key,
        count()                           AS commits,
        SUM(lines_added + lines_removed)  AS loc
    FROM {{ ref('fct_git_commit') }}
    WHERE is_merge_commit = 0
      AND person_key != ''
    GROUP BY tenant_id, person_key
),
clean AS (
    SELECT
        tenant_id,
        person_key,
        SUM(lines_added) AS clean_loc
    FROM {{ ref('fct_git_file_change') }}
    WHERE is_merge_commit = 0
      AND file_category = 'code'
      AND person_key != ''
    GROUP BY tenant_id, person_key
)
SELECT
    coalesce(prs.tenant_id, commits.tenant_id, clean.tenant_id)    AS tenant_id,
    coalesce(prs.person_key, commits.person_key, clean.person_key) AS person_key,
    concat(
        coalesce(prs.tenant_id, commits.tenant_id, clean.tenant_id),
        '|',
        coalesce(prs.person_key, commits.person_key, clean.person_key)
    ) AS unique_key,
    coalesce(prs.prs_created, 0)          AS prs_created,
    coalesce(prs.prs_merged, 0)           AS prs_merged,
    prs.avg_pr_cycle_time_h               AS avg_pr_cycle_time_h,
    coalesce(commits.commits, 0)          AS commits,
    coalesce(commits.loc, 0)              AS loc,
    coalesce(clean.clean_loc, 0)          AS clean_loc
FROM prs
FULL OUTER JOIN commits USING (tenant_id, person_key)
FULL OUTER JOIN clean   USING (tenant_id, person_key)

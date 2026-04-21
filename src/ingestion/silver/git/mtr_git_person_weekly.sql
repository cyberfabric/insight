{{ config(
    materialized='table',
    schema='silver',
    tags=['silver']
) }}

-- All CTEs bucket by commit-date week (toStartOfWeek(commit.date, 1)) so the
-- FULL OUTER JOIN on `week` aligns rows from the same activity window.
-- For prs_merged the week is taken from the merge commit's date (when the
-- merge_commit_hash resolves to a commit row), falling back to the PR
-- closed_on week. This avoids commit-week vs PR-close-week drift.

WITH commits AS (
    SELECT
        tenant_id,
        person_key,
        week,
        count() AS commits
    FROM {{ ref('fct_git_commit') }}
    WHERE is_merge_commit = 0
      AND person_key != ''
      AND date IS NOT NULL
    GROUP BY tenant_id, person_key, week
),
loc AS (
    SELECT
        tenant_id,
        person_key,
        week,
        SUM(if(file_category = 'code', lines_added, 0)) AS code_loc,
        SUM(if(file_category = 'spec', lines_added, 0)) AS spec_lines
    FROM {{ ref('fct_git_file_change') }}
    WHERE is_merge_commit = 0
      AND person_key != ''
      AND week IS NOT NULL
    GROUP BY tenant_id, person_key, week
),
prs AS (
    SELECT
        pr.tenant_id,
        pr.person_key,
        coalesce(mc.week, toStartOfWeek(pr.closed_on, 1)) AS week,
        count() AS prs_merged
    FROM {{ ref('fct_git_pr') }} AS pr
    LEFT JOIN {{ ref('fct_git_commit') }} AS mc
        ON  mc.tenant_id   = pr.tenant_id
        AND mc.source_id   = pr.source_id
        AND mc.project_key = pr.project_key
        AND mc.repo_slug   = pr.repo_slug
        AND mc.commit_hash = pr.merge_commit_hash
    WHERE pr.state_norm = 'merged'
      AND pr.closed_on IS NOT NULL
      AND pr.person_key != ''
    GROUP BY pr.tenant_id, pr.person_key, week
)
SELECT
    coalesce(commits.tenant_id, loc.tenant_id, prs.tenant_id)    AS tenant_id,
    coalesce(commits.person_key, loc.person_key, prs.person_key) AS person_key,
    coalesce(commits.week, loc.week, prs.week)                   AS week,
    concat(
        coalesce(commits.tenant_id, loc.tenant_id, prs.tenant_id),
        '|',
        coalesce(commits.person_key, loc.person_key, prs.person_key),
        '|',
        toString(coalesce(commits.week, loc.week, prs.week))
    ) AS unique_key,
    coalesce(commits.commits, 0)                                 AS commits,
    coalesce(prs.prs_merged, 0)                                  AS prs_merged,
    coalesce(loc.code_loc, 0)                                    AS code_loc,
    coalesce(loc.spec_lines, 0)                                  AS spec_lines
FROM commits
FULL OUTER JOIN loc USING (tenant_id, person_key, week)
FULL OUTER JOIN prs USING (tenant_id, person_key, week)

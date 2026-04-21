-- Add Bitbucket commits gold layer + wire commits into ic_chart_delivery.
-- Depends on 20260417100000_add-org-unit-id-to-views.sql (insight.people,
-- insight.ic_chart_delivery already exist).
--
-- Prerequisites:
--   - bronze_bitbucket_cloud.commits is populated by the ingestion pipeline

-- =====================================================================
-- 1. COMMITS DAILY — one row per (author, day) with commit count
-- =====================================================================
-- insight.people joins on lower(workEmail), so match that casing here too.
-- No domain filter: downstream LEFT JOINs against insight.people effectively
-- scope to actual employees (bots/mirror accounts drop out with org_unit_id
-- NULL and are filtered by the analytics-api OData layer anyway).
CREATE VIEW IF NOT EXISTS insight.commits_daily AS
SELECT
    lower(author_email)                                       AS person_id,
    toDate(parseDateTimeBestEffortOrNull(assumeNotNull(date))) AS metric_date,
    count()                                                   AS commits
FROM bronze_bitbucket_cloud.commits
WHERE author_email IS NOT NULL
  AND author_email != ''
  AND date IS NOT NULL
GROUP BY person_id, metric_date;

-- =====================================================================
-- 2. GIT BULLET ROWS — long-form per-person daily rows for bullet aggregation
-- =====================================================================
-- Matches the contract of other *_bullet_rows views (person_id, org_unit_id,
-- metric_date as String, metric_key, metric_value) so the analytics-api's
-- date-filter injector and the IC_BULLET_GIT query_ref can treat it uniformly.
CREATE VIEW IF NOT EXISTS insight.git_bullet_rows AS
SELECT
    c.person_id            AS person_id,
    p.org_unit_id          AS org_unit_id,
    toString(c.metric_date) AS metric_date,
    'commits'              AS metric_key,
    toFloat64(c.commits)   AS metric_value
FROM insight.commits_daily c
LEFT JOIN insight.people p ON c.person_id = p.person_id;

-- =====================================================================
-- 3. IC CHART DELIVERY — rewrite to populate `commits` from bitbucket
-- =====================================================================
-- The previous version hardcoded commits/prs to 0 because git data wasn't
-- available. Now that commits_daily exists, FULL-OUTER the weekly commit
-- aggregate with the weekly jira aggregate so a person who only commits or
-- only closes tickets in a given week still shows up.
-- prs_merged stays zero until a Bitbucket PR ingestion lands.
DROP VIEW IF EXISTS insight.ic_chart_delivery;

CREATE VIEW insight.ic_chart_delivery AS
WITH
    weekly_commits AS (
        SELECT
            person_id,
            toStartOfWeek(metric_date) AS week,
            sum(commits)                AS commits
        FROM insight.commits_daily
        GROUP BY person_id, week
    ),
    weekly_jira AS (
        SELECT
            person_id,
            toStartOfWeek(metric_date) AS week,
            sum(tasks_closed)           AS tasks_done
        FROM insight.jira_closed_tasks
        GROUP BY person_id, week
    ),
    weeks_all AS (
        SELECT person_id, week FROM weekly_commits
        UNION DISTINCT
        SELECT person_id, week FROM weekly_jira
    )
SELECT
    d.person_id                         AS person_id,
    p.org_unit_id                       AS org_unit_id,
    toString(d.week)                    AS date_bucket,
    toString(d.week)                    AS metric_date,
    toUInt64(ifNull(c.commits, 0))      AS commits,
    toUInt64(0)                         AS prs_merged,
    toUInt64(ifNull(j.tasks_done, 0))   AS tasks_done
FROM weeks_all d
LEFT JOIN insight.people p       ON d.person_id = p.person_id
LEFT JOIN weekly_commits c       ON c.person_id = d.person_id AND c.week = d.week
LEFT JOIN weekly_jira    j       ON j.person_id = d.person_id AND j.week = d.week;

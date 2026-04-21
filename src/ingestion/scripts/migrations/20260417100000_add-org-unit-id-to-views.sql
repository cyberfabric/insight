-- Patch: add org_unit_id column to bullet/IC views.
-- The analytics API always injects org_unit_id from OData $filter,
-- so all views must expose this column.
-- Run on existing installations where 20260417000000 was already applied.

-- Drop views that need rebuilding (reverse dependency order)
DROP VIEW IF EXISTS insight.ic_timeoff;
DROP VIEW IF EXISTS insight.ic_drill;
DROP VIEW IF EXISTS insight.ic_chart_loc;
DROP VIEW IF EXISTS insight.ic_chart_delivery;
DROP VIEW IF EXISTS insight.ic_kpis;
DROP VIEW IF EXISTS insight.ai_bullet_rows;
DROP VIEW IF EXISTS insight.code_quality_bullet_rows;
DROP VIEW IF EXISTS insight.task_delivery_bullet_rows;
DROP VIEW IF EXISTS insight.collab_bullet_rows;

-- 9. COLLAB BULLET ROWS
CREATE VIEW insight.collab_bullet_rows AS
SELECT c.person_id, p.org_unit_id, c.metric_date, 'm365_emails_sent' AS metric_key, c.emails_sent AS metric_value
FROM insight.comms_daily c LEFT JOIN insight.people p ON c.person_id = p.person_id
UNION ALL
SELECT c.person_id, p.org_unit_id, c.metric_date, 'zoom_calls', c.zoom_calls
FROM insight.comms_daily c LEFT JOIN insight.people p ON c.person_id = p.person_id
UNION ALL
SELECT c.person_id, p.org_unit_id, c.metric_date, 'meeting_hours', c.meeting_hours
FROM insight.comms_daily c LEFT JOIN insight.people p ON c.person_id = p.person_id
UNION ALL
SELECT c.person_id, p.org_unit_id, c.metric_date, 'm365_teams_messages', c.teams_messages
FROM insight.comms_daily c LEFT JOIN insight.people p ON c.person_id = p.person_id
UNION ALL
SELECT c.person_id, p.org_unit_id, c.metric_date, 'm365_files_shared', c.files_shared
FROM insight.comms_daily c LEFT JOIN insight.people p ON c.person_id = p.person_id
UNION ALL
SELECT c.person_id, p.org_unit_id, c.metric_date, 'meeting_free',
    if(c.meeting_hours + c.teams_meetings = 0, 1, 0)
FROM insight.comms_daily c LEFT JOIN insight.people p ON c.person_id = p.person_id;

-- 10. TASK DELIVERY BULLET ROWS
CREATE VIEW insight.task_delivery_bullet_rows AS
SELECT j.person_id, p.org_unit_id, toString(j.metric_date) AS metric_date, 'tasks_completed' AS metric_key, toFloat64(j.tasks_closed) AS metric_value
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id
UNION ALL
SELECT j.person_id, p.org_unit_id, toString(j.metric_date), 'task_reopen_rate', toFloat64(0)
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id
UNION ALL
SELECT j.person_id, p.org_unit_id, toString(j.metric_date), 'due_date_compliance',
    if(j.has_due_date_count > 0, round(j.on_time_count / j.has_due_date_count * 100, 1), 0)
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id;

-- 11. CODE QUALITY BULLET ROWS
CREATE VIEW insight.code_quality_bullet_rows AS
SELECT j.person_id, p.org_unit_id, toString(j.metric_date) AS metric_date, 'bugs_fixed' AS metric_key, toFloat64(j.bugs_fixed) AS metric_value
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id
UNION ALL
SELECT j.person_id, p.org_unit_id, toString(j.metric_date), 'prs_per_dev', toFloat64(0)
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id
UNION ALL
SELECT j.person_id, p.org_unit_id, toString(j.metric_date), 'pr_cycle_time', toFloat64(0)
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id
UNION ALL
SELECT j.person_id, p.org_unit_id, toString(j.metric_date), 'build_success', toFloat64(0)
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id;

-- 12. AI BULLET ROWS
CREATE VIEW insight.ai_bullet_rows AS
SELECT '' AS person_id, '' AS org_unit_id, '' AS metric_date, '' AS metric_key, toFloat64(0) AS metric_value
FROM system.one WHERE 0;

-- 15. IC KPIS
CREATE VIEW insight.ic_kpis AS
SELECT
    j.person_id                                     AS person_id,
    p.org_unit_id                                   AS org_unit_id,
    toString(j.metric_date)                         AS metric_date,
    toFloat64(0)                                     AS loc,
    toFloat64(0)                                     AS ai_loc_share_pct,
    toFloat64(0)                                     AS prs_merged,
    toFloat64(0)                                     AS pr_cycle_time_h,
    greatest(0, least(100, round(100 - (ifNull(c.meeting_hours, 0) / 8.0) * 100, 1))) AS focus_time_pct,
    toFloat64(j.tasks_closed)                        AS tasks_closed,
    toFloat64(j.bugs_fixed)                          AS bugs_fixed,
    CAST(NULL AS Nullable(Float64))                  AS build_success_pct,
    toFloat64(0)                                     AS ai_sessions
FROM insight.jira_closed_tasks j
LEFT JOIN insight.people p ON j.person_id = p.person_id
LEFT JOIN insight.comms_daily c ON j.person_id = c.person_id
    AND toString(j.metric_date) = c.metric_date;

-- 16. IC CHART DELIVERY
CREATE VIEW insight.ic_chart_delivery AS
SELECT
    sub.person_id,
    p.org_unit_id AS org_unit_id,
    toString(week_start) AS date_bucket,
    toString(week_start) AS metric_date,
    toUInt64(0)          AS commits,
    toUInt64(0)          AS prs_merged,
    sum(tasks_closed)    AS tasks_done
FROM (
    SELECT person_id, toStartOfWeek(metric_date) AS week_start, tasks_closed
    FROM insight.jira_closed_tasks
) sub
LEFT JOIN insight.people p ON sub.person_id = p.person_id
GROUP BY sub.person_id, p.org_unit_id, week_start;

-- 17. IC CHART LOC
CREATE VIEW insight.ic_chart_loc AS
SELECT
    sub.person_id,
    p.org_unit_id AS org_unit_id,
    toString(week_start) AS date_bucket,
    toString(week_start) AS metric_date,
    toFloat64(0) AS ai_loc,
    toFloat64(0) AS code_loc,
    toFloat64(0) AS spec_lines
FROM (
    SELECT person_id, toStartOfWeek(metric_date) AS week_start
    FROM insight.jira_closed_tasks
) sub
LEFT JOIN insight.people p ON sub.person_id = p.person_id
GROUP BY sub.person_id, p.org_unit_id, week_start;

-- 18. IC DRILL
CREATE VIEW insight.ic_drill AS
SELECT '' AS person_id, '' AS org_unit_id, '' AS metric_date, '' AS drill_id,
    '' AS title, '' AS source, '' AS src_class, '' AS value, '' AS filter,
    CAST([] AS Array(String)) AS columns, CAST([] AS Array(String)) AS rows
FROM system.one WHERE 0;

-- 19. IC TIMEOFF
CREATE VIEW insight.ic_timeoff AS
SELECT '' AS person_id, '' AS org_unit_id, '' AS metric_date,
    toUInt32(0) AS days, '' AS date_range, '' AS bamboo_hr_url
FROM system.one WHERE 0;

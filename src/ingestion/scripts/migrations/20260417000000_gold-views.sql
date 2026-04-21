-- Gold views for Insight dashboards.
-- Builds on bronze_* tables to provide columns expected by FE rawTypes.
-- MVP: single tenant, no insight_tenant_id filtering.
--
-- Prerequisites:
--   - Database `insight` exists
--   - Bronze databases: bronze_bamboohr, bronze_jira, bronze_m365, bronze_zoom
--   - Table: silver.class_comms_events

-- =====================================================================
-- 1. PEOPLE — deduped person lookup from BambooHR
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.people AS
SELECT
    person_id,
    argMax(displayName, _airbyte_extracted_at)  AS display_name,
    argMax(department, _airbyte_extracted_at)    AS org_unit_id,
    argMax(department, _airbyte_extracted_at)    AS org_unit_name,
    argMax(
        multiIf(
            jobTitle ILIKE '%senior%' OR jobTitle ILIKE '%lead%' OR jobTitle ILIKE '%principal%' OR jobTitle ILIKE '%architect%' OR jobTitle ILIKE '%director%' OR jobTitle ILIKE '%head%', 'Senior',
            jobTitle ILIKE '%junior%' OR jobTitle ILIKE '%intern%' OR jobTitle ILIKE '%trainee%', 'Junior',
            'Mid'
        ),
        _airbyte_extracted_at
    ) AS seniority,
    argMax(jobTitle, _airbyte_extracted_at)      AS job_title,
    argMax(status, _airbyte_extracted_at)         AS status
FROM bronze_bamboohr.employees
WHERE workEmail IS NOT NULL AND workEmail != ''
GROUP BY lower(workEmail) AS person_id;

-- =====================================================================
-- 2. JIRA — tasks per person per day (raw view, used only for INSERT)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.jira_person_daily AS
SELECT
    lower(JSONExtractString(custom_fields_json, 'assignee', 'emailAddress')) AS person_id,
    toDate(parseDateTimeBestEffort(updated))                                 AS metric_date,
    issue_type,
    JSONExtractString(custom_fields_json, 'status', 'name')                  AS status_name,
    JSONExtractString(custom_fields_json, 'resolution', 'name')              AS resolution,
    due_date,
    JSONExtractFloat(custom_fields_json, 'timeoriginalestimate')             AS time_estimate_sec,
    JSONExtractFloat(custom_fields_json, 'timespent')                        AS time_spent_sec,
    id_readable
FROM bronze_jira.jira_issue
WHERE person_id != '';

-- =====================================================================
-- 3. JIRA CLOSED TASKS — materialized table (JSON extraction too slow for views)
-- =====================================================================
CREATE TABLE IF NOT EXISTS insight.jira_closed_tasks (
    person_id String,
    metric_date Date,
    tasks_closed UInt64,
    bugs_fixed UInt64,
    on_time_count UInt64,
    has_due_date_count UInt64,
    avg_time_spent Nullable(Float64),
    avg_time_estimate Nullable(Float64)
) ENGINE = MergeTree()
ORDER BY (person_id, metric_date);

INSERT INTO insight.jira_closed_tasks
SELECT
    lower(JSONExtractString(custom_fields_json, 'assignee', 'emailAddress')) AS person_id,
    toDate(parseDateTimeBestEffort(updated)) AS metric_date,
    count() AS tasks_closed,
    countIf(issue_type = 'Bug') AS bugs_fixed,
    countIf(due_date IS NOT NULL AND due_date != ''
            AND toDate(parseDateTimeBestEffort(updated)) <= toDate(due_date)) AS on_time_count,
    countIf(due_date IS NOT NULL AND due_date != '') AS has_due_date_count,
    avgIf(JSONExtractFloat(custom_fields_json, 'timespent'),
          JSONExtractFloat(custom_fields_json, 'timeoriginalestimate') > 0) AS avg_time_spent,
    avgIf(JSONExtractFloat(custom_fields_json, 'timeoriginalestimate'),
          JSONExtractFloat(custom_fields_json, 'timeoriginalestimate') > 0) AS avg_time_estimate
FROM bronze_jira.jira_issue
WHERE lower(JSONExtractString(custom_fields_json, 'assignee', 'emailAddress')) != ''
  AND JSONExtractString(custom_fields_json, 'status', 'name') IN ('Closed', 'Resolved', 'Verified')
GROUP BY person_id, metric_date;

-- =====================================================================
-- 4. M365 TEAMS — messages per person per day
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.teams_person_daily AS
SELECT
    lower(userPrincipalName)                                            AS person_id,
    toDate(lastActivityDate)                                            AS metric_date,
    toFloat64(ifNull(teamChatMessageCount, 0))
      + toFloat64(ifNull(privateChatMessageCount, 0))                   AS teams_messages,
    toFloat64(ifNull(meetingsAttendedCount, 0))                         AS teams_meetings,
    toFloat64(ifNull(callCount, 0))                                     AS teams_calls
FROM bronze_m365.teams_activity
WHERE userPrincipalName IS NOT NULL
  AND userPrincipalName != ''
  AND userPrincipalName != '(Unknown)';

-- =====================================================================
-- 5. M365 FILES — OneDrive + SharePoint per person per day
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.files_person_daily AS
SELECT
    person_id,
    metric_date,
    sum(shared_internally) + sum(shared_externally) AS files_shared
FROM (
    SELECT
        lower(userPrincipalName) AS person_id,
        toDate(lastActivityDate) AS metric_date,
        toFloat64(ifNull(sharedInternallyFileCount, 0)) AS shared_internally,
        toFloat64(ifNull(sharedExternallyFileCount, 0)) AS shared_externally
    FROM bronze_m365.onedrive_activity
    WHERE userPrincipalName IS NOT NULL AND userPrincipalName != ''
    UNION ALL
    SELECT
        lower(userPrincipalName) AS person_id,
        toDate(lastActivityDate) AS metric_date,
        toFloat64(ifNull(sharedInternallyFileCount, 0)) AS shared_internally,
        toFloat64(ifNull(sharedExternallyFileCount, 0)) AS shared_externally
    FROM bronze_m365.sharepoint_activity
    WHERE userPrincipalName IS NOT NULL AND userPrincipalName != ''
) sub
GROUP BY person_id, metric_date;

-- =====================================================================
-- 6. COMMS DAILY — unified: email + zoom + teams + files
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.comms_daily AS
SELECT
    person_id,
    toString(metric_date) AS metric_date,
    sum(emails_sent)      AS emails_sent,
    sum(zoom_calls)       AS zoom_calls,
    sum(meeting_hours)    AS meeting_hours,
    sum(teams_messages)   AS teams_messages,
    sum(teams_meetings)   AS teams_meetings,
    sum(files_shared)     AS files_shared
FROM (
    SELECT
        lower(user_email) AS person_id,
        toDate(activity_date) AS metric_date,
        toFloat64(emails_sent) AS emails_sent,
        toFloat64(0) AS zoom_calls,
        toFloat64(0) AS meeting_hours,
        toFloat64(0) AS teams_messages,
        toFloat64(0) AS teams_meetings,
        toFloat64(0) AS files_shared
    FROM silver.class_comms_events
    UNION ALL
    SELECT
        lower(p.email) AS person_id,
        toDate(parseDateTimeBestEffort(p.join_time)) AS metric_date,
        toFloat64(0) AS emails_sent,
        toFloat64(1) AS zoom_calls,
        dateDiff('second', parseDateTimeBestEffort(p.join_time), parseDateTimeBestEffort(p.leave_time)) / 3600.0 AS meeting_hours,
        toFloat64(0) AS teams_messages,
        toFloat64(0) AS teams_meetings,
        toFloat64(0) AS files_shared
    FROM bronze_zoom.participants p
    WHERE p.email IS NOT NULL AND p.email != ''
    UNION ALL
    SELECT
        lower(userPrincipalName) AS person_id,
        toDate(lastActivityDate) AS metric_date,
        toFloat64(0) AS emails_sent,
        toFloat64(0) AS zoom_calls,
        toFloat64(0) AS meeting_hours,
        toFloat64(ifNull(teamChatMessageCount, 0)) + toFloat64(ifNull(privateChatMessageCount, 0)) AS teams_messages,
        toFloat64(ifNull(meetingsAttendedCount, 0)) AS teams_meetings,
        toFloat64(0) AS files_shared
    FROM bronze_m365.teams_activity
    WHERE userPrincipalName IS NOT NULL AND userPrincipalName != '' AND userPrincipalName != '(Unknown)'
    UNION ALL
    SELECT
        lower(userPrincipalName) AS person_id,
        toDate(lastActivityDate) AS metric_date,
        toFloat64(0), toFloat64(0), toFloat64(0), toFloat64(0), toFloat64(0),
        toFloat64(ifNull(sharedInternallyFileCount, 0)) + toFloat64(ifNull(sharedExternallyFileCount, 0))
    FROM bronze_m365.onedrive_activity
    WHERE userPrincipalName IS NOT NULL AND userPrincipalName != ''
    UNION ALL
    SELECT
        lower(userPrincipalName) AS person_id,
        toDate(lastActivityDate) AS metric_date,
        toFloat64(0), toFloat64(0), toFloat64(0), toFloat64(0), toFloat64(0),
        toFloat64(ifNull(sharedInternallyFileCount, 0)) + toFloat64(ifNull(sharedExternallyFileCount, 0))
    FROM bronze_m365.sharepoint_activity
    WHERE userPrincipalName IS NOT NULL AND userPrincipalName != ''
) sub
GROUP BY person_id, metric_date;

-- =====================================================================
-- 7. EMAIL DAILY — backward compat
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.email_daily AS
SELECT
    lower(user_email) AS person_id,
    activity_date     AS metric_date,
    lower(user_email) AS user_email,
    emails_sent,
    source
FROM silver.class_comms_events;

-- =====================================================================
-- 8. ZOOM PERSON DAILY — backward compat
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.zoom_person_daily AS
SELECT
    lower(p.email) AS person_id,
    toDate(parseDateTimeBestEffort(p.join_time)) AS metric_date,
    lower(p.email) AS user_email,
    countDistinct(p.meeting_uuid) AS zoom_calls,
    sum(dateDiff('second', parseDateTimeBestEffort(p.join_time), parseDateTimeBestEffort(p.leave_time))) / 3600.0 AS meeting_hours
FROM bronze_zoom.participants p
WHERE p.email IS NOT NULL AND p.email != ''
GROUP BY lower(p.email), toDate(parseDateTimeBestEffort(p.join_time));

-- =====================================================================
-- 9. COLLAB BULLET ROWS — all collab metrics unpivoted (with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.collab_bullet_rows AS
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

-- =====================================================================
-- 10. TASK DELIVERY BULLET ROWS (with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.task_delivery_bullet_rows AS
SELECT j.person_id, p.org_unit_id, toString(j.metric_date) AS metric_date, 'tasks_completed' AS metric_key, toFloat64(j.tasks_closed) AS metric_value
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id
UNION ALL
SELECT j.person_id, p.org_unit_id, toString(j.metric_date), 'task_reopen_rate', toFloat64(0)
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id
UNION ALL
SELECT j.person_id, p.org_unit_id, toString(j.metric_date), 'due_date_compliance',
    if(j.has_due_date_count > 0, round(j.on_time_count / j.has_due_date_count * 100, 1), 0)
FROM insight.jira_closed_tasks j LEFT JOIN insight.people p ON j.person_id = p.person_id;

-- =====================================================================
-- 11. CODE QUALITY BULLET ROWS (with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.code_quality_bullet_rows AS
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

-- =====================================================================
-- 12. AI BULLET ROWS — empty placeholder (with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.ai_bullet_rows AS
SELECT '' AS person_id, '' AS org_unit_id, '' AS metric_date, '' AS metric_key, toFloat64(0) AS metric_value
FROM system.one WHERE 0;

-- =====================================================================
-- 13. EXEC SUMMARY — FE: RawExecSummaryRow
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.exec_summary AS
SELECT
    p.org_unit_id                                    AS org_unit_id,
    p.org_unit_name                                  AS org_unit_name,
    p.headcount                                      AS headcount,
    ifNull(j.tasks_closed, 0)                        AS tasks_closed,
    ifNull(j.bugs_fixed, 0)                          AS bugs_fixed,
    CAST(NULL AS Nullable(Float64))                  AS build_success_pct,
    greatest(0, least(100, round(ifNull(c.focus_time_pct, 100), 1))) AS focus_time_pct,
    toFloat64(0)                                     AS ai_adoption_pct,
    toFloat64(0)                                     AS ai_loc_share_pct,
    toFloat64(0)                                     AS pr_cycle_time_h,
    ifNull(j.metric_date, c.metric_date)             AS metric_date
FROM (
    SELECT org_unit_id, org_unit_name,
           toUInt32(count()) AS headcount
    FROM insight.people WHERE status = 'Active'
    GROUP BY org_unit_id, org_unit_name
) p
LEFT JOIN (
    SELECT pe.org_unit_id, toString(j.metric_date) AS metric_date,
           sum(j.tasks_closed) AS tasks_closed,
           sum(j.bugs_fixed)   AS bugs_fixed
    FROM insight.jira_closed_tasks j
    JOIN insight.people pe ON j.person_id = pe.person_id AND pe.status = 'Active'
    GROUP BY pe.org_unit_id, j.metric_date
) j ON p.org_unit_id = j.org_unit_id
LEFT JOIN (
    SELECT pe.org_unit_id, c.metric_date,
           round(100 - avg(c.meeting_hours) / 8.0 * 100, 1) AS focus_time_pct
    FROM insight.comms_daily c
    JOIN insight.people pe ON c.person_id = pe.person_id AND pe.status = 'Active'
    GROUP BY pe.org_unit_id, c.metric_date
) c ON p.org_unit_id = c.org_unit_id AND j.metric_date = c.metric_date;

-- =====================================================================
-- 14. TEAM MEMBER — FE: RawTeamMemberRow
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.team_member AS
SELECT
    p.person_id                                     AS person_id,
    p.display_name                                  AS display_name,
    p.seniority                                     AS seniority,
    p.org_unit_id                                   AS org_unit_id,
    toFloat64(ifNull(j.tasks_closed, 0))            AS tasks_closed,
    toFloat64(ifNull(j.bugs_fixed, 0))              AS bugs_fixed,
    greatest(0, round(8.0 - ifNull(c.meeting_hours, 0), 1)) AS dev_time_h,
    toFloat64(0)                                    AS prs_merged,
    CAST(NULL AS Nullable(Float64))                 AS build_success_pct,
    greatest(0, least(100, round(100 - ifNull(c.meeting_hours, 0) / 8.0 * 100, 1))) AS focus_time_pct,
    CAST([] AS Array(String))                       AS ai_tools,
    toFloat64(0)                                    AS ai_loc_share_pct,
    ifNull(j.metric_date, c.metric_date)            AS metric_date
FROM insight.people p
LEFT JOIN (
    SELECT person_id, toString(metric_date) AS metric_date,
           sum(tasks_closed) AS tasks_closed, sum(bugs_fixed) AS bugs_fixed
    FROM insight.jira_closed_tasks
    GROUP BY person_id, metric_date
) j ON p.person_id = j.person_id
LEFT JOIN (
    SELECT person_id, metric_date,
           sum(meeting_hours) AS meeting_hours
    FROM insight.comms_daily
    GROUP BY person_id, metric_date
) c ON p.person_id = c.person_id AND j.metric_date = c.metric_date
WHERE p.status = 'Active';

-- =====================================================================
-- 15. IC KPIS — FE: RawIcAggregateRow (with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.ic_kpis AS
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

-- =====================================================================
-- 16. IC CHART DELIVERY — FE: RawDeliveryTrendRow (with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.ic_chart_delivery AS
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

-- =====================================================================
-- 17. IC CHART LOC — FE: RawLocTrendRow (placeholder, with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.ic_chart_loc AS
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

-- =====================================================================
-- 18. IC DRILL — empty placeholder (with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.ic_drill AS
SELECT '' AS person_id, '' AS org_unit_id, '' AS metric_date, '' AS drill_id,
    '' AS title, '' AS source, '' AS src_class, '' AS value, '' AS filter,
    CAST([] AS Array(String)) AS columns, CAST([] AS Array(String)) AS rows
FROM system.one WHERE 0;

-- =====================================================================
-- 19. IC TIMEOFF — FE: RawTimeOffRow (placeholder, with org_unit_id)
-- =====================================================================
CREATE VIEW IF NOT EXISTS insight.ic_timeoff AS
SELECT '' AS person_id, '' AS org_unit_id, '' AS metric_date,
    toUInt32(0) AS days, '' AS date_range, '' AS bamboo_hr_url
FROM system.one WHERE 0;

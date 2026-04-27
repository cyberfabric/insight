-- =====================================================================
-- Insight gold views — read from silver instead of bronze
-- =====================================================================
--
-- Bronze tables are append-only archives — Airbyte writes every sync's
-- rows fresh, so a single business entity accumulates ×N copies (×2.5 for
-- bitbucket commits, ×1.5 for collab activity etc on a busy cluster).
--
-- The earlier gold views in 20260422000000_gold-views.sql aggregated
-- bronze directly — `count()`/`sum()` on duplicated rows = inflated metrics
-- visible in the backend.
--
-- This migration rewrites the views that have a clean silver equivalent
-- to read from silver. Silver dedups via ReplacingMergeTree(_version)
-- (after #237) so each business entity contributes once.
--
-- Views NOT migrated here:
--   - insight.people                          → bronze with argMax dedup,
--                                               already correct
--   - insight.jira_person_daily               → needs a new silver model
--                                               (silver.class_task_daily)
--   - insight.collab_bullet_rows              → reads bronze_slack.users_details
--                                               (slack email send-counts);
--                                               silver.class_collab_chat_activity
--                                               doesn't carry that metric yet
--   - insight.{ai_bullet_rows, exec_summary,
--              team_member, ic_kpis,
--              ic_chart_loc}                  → silver.class_ai_dev_usage is
--                                               missing `totalLinesAdded`
--                                               needed for ai_loc_share
--                                               metrics; can be migrated
--                                               after a follow-up that
--                                               extends the silver schema.
-- =====================================================================

-- ---------------------------------------------------------------------
-- commits_daily: per-person daily commit count
-- ---------------------------------------------------------------------
--   bronze_bitbucket_cloud.commits   ×2.48 dup factor (live)
-- → silver.class_git_commits         dedup'd by RMT (after #237)
DROP VIEW IF EXISTS insight.commits_daily;
CREATE VIEW insight.commits_daily AS
SELECT
    lower(author_email)                       AS person_id,
    toDate(date)                              AS metric_date,
    count()                                   AS commits
FROM silver.class_git_commits
WHERE author_email != ''
  AND author_email LIKE '%@virtuozzo.com'
  AND date IS NOT NULL
GROUP BY person_id, metric_date;

-- ---------------------------------------------------------------------
-- zoom_person_daily: per-person daily zoom call counts and meeting hours
-- ---------------------------------------------------------------------
--   bronze_zoom.participants                  raw participants × syncs
-- → silver.class_collab_meeting_activity      already aggregated per
--                                             (email, day) for zoom
DROP VIEW IF EXISTS insight.zoom_person_daily;
CREATE VIEW insight.zoom_person_daily AS
SELECT
    lower(email)                              AS person_id,
    date                                      AS metric_date,
    lower(email)                              AS user_email,
    toUInt64(coalesce(calls_count, 0))        AS zoom_calls,
    toFloat64(coalesce(audio_duration_seconds, 0)) / 3600.0
                                              AS meeting_hours
FROM silver.class_collab_meeting_activity
WHERE data_source = 'insight_zoom'
  AND email IS NOT NULL
  AND email != '';

-- ---------------------------------------------------------------------
-- teams_person_daily: per-person daily teams chat msgs / meetings / calls
-- ---------------------------------------------------------------------
--   bronze_m365.teams_activity                raw daily reports × syncs
-- → silver.class_collab_{chat,meeting}_activity  m365 partition only
DROP VIEW IF EXISTS insight.teams_person_daily;
CREATE VIEW insight.teams_person_daily AS
SELECT
    lower(coalesce(c.email, m.email))         AS person_id,
    coalesce(c.date, m.date)                  AS metric_date,
    toFloat64(coalesce(c.total_chat_messages, 0))
                                              AS teams_messages,
    toFloat64(coalesce(m.meetings_attended, 0))
                                              AS teams_meetings,
    toFloat64(coalesce(m.calls_count, 0))     AS teams_calls
FROM silver.class_collab_chat_activity AS c
FULL OUTER JOIN silver.class_collab_meeting_activity AS m
    ON  lower(c.email) = lower(m.email)
    AND c.date         = m.date
    AND m.data_source  = 'insight_m365'
WHERE c.data_source = 'insight_m365'
   OR m.data_source = 'insight_m365';

-- ---------------------------------------------------------------------
-- files_person_daily: per-person daily files-shared count (OneDrive+SP)
-- ---------------------------------------------------------------------
--   bronze_m365.{onedrive,sharepoint}_activity  raw daily reports × syncs
-- → silver.class_collab_document_activity       already covers both
DROP VIEW IF EXISTS insight.files_person_daily;
CREATE VIEW insight.files_person_daily AS
SELECT
    lower(email)                              AS person_id,
    date                                      AS metric_date,
    toFloat64(sum(coalesce(shared_internally_count, 0)))
        + toFloat64(sum(coalesce(shared_externally_count, 0)))
                                              AS files_shared
FROM silver.class_collab_document_activity
WHERE data_source = 'insight_m365'
  AND email IS NOT NULL
  AND email != ''
GROUP BY lower(email), date;

-- ---------------------------------------------------------------------
-- comms_daily: per-person daily comms (emails, zoom, teams, files)
-- ---------------------------------------------------------------------
--   bronze_m365 × 3 + bronze_zoom.participants
-- → silver.class_collab_{chat,document,email,meeting}_activity
DROP VIEW IF EXISTS insight.comms_daily;
CREATE VIEW insight.comms_daily AS
SELECT
    person_id,
    toString(metric_date)                     AS metric_date,
    sum(emails_sent)                          AS emails_sent,
    sum(zoom_calls)                           AS zoom_calls,
    sum(meeting_hours)                        AS meeting_hours,
    sum(teams_messages)                       AS teams_messages,
    sum(teams_meetings)                       AS teams_meetings,
    sum(files_shared)                         AS files_shared
FROM (
    -- m365 emails
    SELECT
        lower(person_key)                     AS person_id,
        date                                  AS metric_date,
        toFloat64(coalesce(sent_count, 0))    AS emails_sent,
        toFloat64(0)                          AS zoom_calls,
        toFloat64(0)                          AS meeting_hours,
        toFloat64(0)                          AS teams_messages,
        toFloat64(0)                          AS teams_meetings,
        toFloat64(0)                          AS files_shared
    FROM silver.class_collab_email_activity
    WHERE data_source = 'insight_m365'

    UNION ALL

    -- zoom calls
    SELECT
        lower(email),
        date,
        toFloat64(0),
        toFloat64(coalesce(calls_count, 0)),
        toFloat64(coalesce(audio_duration_seconds, 0)) / 3600.0,
        toFloat64(0),
        toFloat64(0),
        toFloat64(0)
    FROM silver.class_collab_meeting_activity
    WHERE data_source = 'insight_zoom'

    UNION ALL

    -- m365 teams chat + meetings
    SELECT
        lower(email),
        date,
        toFloat64(0),
        toFloat64(0),
        toFloat64(0),
        toFloat64(coalesce(total_chat_messages, 0)),
        toFloat64(0),
        toFloat64(0)
    FROM silver.class_collab_chat_activity
    WHERE data_source = 'insight_m365'

    UNION ALL

    SELECT
        lower(email),
        date,
        toFloat64(0),
        toFloat64(0),
        toFloat64(0),
        toFloat64(0),
        toFloat64(coalesce(meetings_attended, 0)),
        toFloat64(0)
    FROM silver.class_collab_meeting_activity
    WHERE data_source = 'insight_m365'

    UNION ALL

    -- m365 files (onedrive + sharepoint already merged in silver)
    SELECT
        lower(email),
        date,
        toFloat64(0),
        toFloat64(0),
        toFloat64(0),
        toFloat64(0),
        toFloat64(0),
        toFloat64(coalesce(shared_internally_count, 0))
            + toFloat64(coalesce(shared_externally_count, 0))
    FROM silver.class_collab_document_activity
    WHERE data_source = 'insight_m365'
) AS sub
WHERE person_id IS NOT NULL AND person_id != ''
GROUP BY person_id, metric_date;

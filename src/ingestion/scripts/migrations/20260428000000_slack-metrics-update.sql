-- =====================================================================
-- Slack metrics update — rename mislabeled keys + add consistency metrics
-- =====================================================================
--
-- Two of the existing Slack bullet metrics misrepresented their underlying
-- data, and two new metrics are added to surface engagement consistency
-- (not just raw volume).
--
-- Renames
--   slack_message_engagement   → slack_messages_sent
--     was computed from silver.class_collab_chat_activity.total_chat_messages,
--     i.e. raw messages a user posted on Slack that day. The label "Message
--     Engagement (avg replies per thread)" implied reply-level data, which
--     Slack's analytics endpoint does not split out.
--   slack_thread_participation → slack_channel_posts
--     was computed from channel_messages_posted_count, i.e. all messages in
--     public channels — not just replies to others' threads. Bronze does not
--     separate post vs reply.
--
-- New metrics (both from total_chat_messages)
--   slack_active_days          per-day = 1 if user sent any messages, else 0.
--                              Aggregates to count of active days in period
--                              (sum). Higher = more consistent presence.
--   slack_msgs_per_active_day  per-day = total_chat_messages on active days,
--                              NULL otherwise. Aggregates as avg (default),
--                              which CH avg() computes over non-NULL values
--                              → mean intensity when active. Avoids the
--                              "100 messages on Monday, silent the rest" /
--                              "20 messages every day" being indistinguishable
--                              by raw period total.
--
-- Supersedes the slack branch of insight.collab_bullet_rows defined in
-- 20260427120000_views-from-silver.sql. View is DROP+CREATE.
-- =====================================================================

DROP VIEW IF EXISTS insight.collab_bullet_rows;
CREATE VIEW insight.collab_bullet_rows AS
SELECT
    lower(e.email)                                AS person_id,
    p.org_unit_id,
    toString(e.date)                              AS metric_date,
    'm365_emails_sent'                            AS metric_key,
    toFloat64(ifNull(e.sent_count, 0))            AS metric_value
FROM silver.class_collab_email_activity AS e
LEFT JOIN insight.people AS p ON lower(e.email) = p.person_id
WHERE e.data_source = 'insight_m365'

UNION ALL
SELECT
    lower(m.email), p.org_unit_id, toString(m.date), 'zoom_calls',
    toFloat64(ifNull(m.calls_count, 0))
FROM silver.class_collab_meeting_activity AS m
LEFT JOIN insight.people AS p ON lower(m.email) = p.person_id
WHERE m.data_source = 'insight_zoom'

UNION ALL
SELECT
    f.email, p.org_unit_id, toString(f.day), 'meeting_hours',
    least(toFloat64(ifNull(f.meeting_hours, 0)), f.working_hours_per_day)
FROM silver.class_focus_metrics AS f
LEFT JOIN insight.people AS p ON f.email = p.person_id

UNION ALL
SELECT
    lower(c.email), p.org_unit_id, toString(c.date), 'm365_teams_messages',
    toFloat64(c.total_chat_messages)
FROM silver.class_collab_chat_activity AS c
LEFT JOIN insight.people AS p ON lower(c.email) = p.person_id
WHERE c.data_source = 'insight_m365'

UNION ALL
SELECT
    lower(d.email), p.org_unit_id, toString(d.date), 'm365_files_shared',
    toFloat64(ifNull(d.shared_internally_count, 0)) +
    toFloat64(ifNull(d.shared_externally_count, 0))
FROM silver.class_collab_document_activity AS d
LEFT JOIN insight.people AS p ON lower(d.email) = p.person_id
WHERE d.data_source = 'insight_m365'

UNION ALL
SELECT
    f.email, p.org_unit_id, toString(f.day), 'meeting_free',
    if(ifNull(f.meeting_hours, 0) = 0, toFloat64(1), toFloat64(0))
FROM silver.class_focus_metrics AS f
LEFT JOIN insight.people AS p ON f.email = p.person_id

-- Slack ----------------------------------------------------------------
UNION ALL
SELECT
    lower(s.email), p.org_unit_id, toString(s.date), 'slack_messages_sent',
    toFloat64(ifNull(s.total_chat_messages, 0))
FROM silver.class_collab_chat_activity AS s
LEFT JOIN insight.people AS p ON lower(s.email) = p.person_id
WHERE s.data_source = 'insight_slack'

UNION ALL
SELECT
    lower(s.email), p.org_unit_id, toString(s.date), 'slack_channel_posts',
    toFloat64(ifNull(s.channel_posts, 0))
FROM silver.class_collab_chat_activity AS s
LEFT JOIN insight.people AS p ON lower(s.email) = p.person_id
WHERE s.data_source = 'insight_slack'

UNION ALL
SELECT
    lower(s.email), p.org_unit_id, toString(s.date), 'slack_active_days',
    if(ifNull(s.total_chat_messages, 0) > 0, toFloat64(1), toFloat64(0))
FROM silver.class_collab_chat_activity AS s
LEFT JOIN insight.people AS p ON lower(s.email) = p.person_id
WHERE s.data_source = 'insight_slack'

UNION ALL
SELECT
    lower(s.email), p.org_unit_id, toString(s.date), 'slack_msgs_per_active_day',
    -- Emit msgs only on active days; NULL otherwise so avg() aggregates
    -- to mean intensity over active days (CH avg ignores NULLs).
    if(ifNull(s.total_chat_messages, 0) > 0,
       toFloat64(s.total_chat_messages),
       CAST(NULL AS Nullable(Float64)))
FROM silver.class_collab_chat_activity AS s
LEFT JOIN insight.people AS p ON lower(s.email) = p.person_id
WHERE s.data_source = 'insight_slack'

UNION ALL
SELECT
    lower(s.email), p.org_unit_id, toString(s.date), 'slack_dm_ratio',
    -- 0 messages → no rate to compute; return NULL not 0.
    if(ifNull(s.total_chat_messages, 0) > 0,
       round(((toFloat64(ifNull(s.total_chat_messages, 0)) -
               toFloat64(ifNull(s.channel_posts, 0))) /
              toFloat64(s.total_chat_messages)) * 100, 1),
       CAST(NULL AS Nullable(Float64)))
FROM silver.class_collab_chat_activity AS s
LEFT JOIN insight.people AS p ON lower(s.email) = p.person_id
WHERE s.data_source = 'insight_slack';

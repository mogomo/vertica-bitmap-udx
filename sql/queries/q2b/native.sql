-- Q2b exact distinct users of web and app on 2026-11-01 and 2026-11-02 (UTC), native SQL.
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = ${tenant} AND channel IN ('web', 'app')
  AND event_ts >= TIMESTAMP '2026-11-01 00:00:00' AND event_ts < TIMESTAMP '2026-11-03 00:00:00';

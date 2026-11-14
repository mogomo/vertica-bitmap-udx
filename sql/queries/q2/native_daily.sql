-- Q2 distinct web users per day, native SQL.
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = ${tenant} AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-11-01 00:00:00' AND event_ts < TIMESTAMP '2026-11-03 00:00:00'
GROUP BY 1;

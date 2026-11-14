SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel IN ('web', 'app')
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00';

SELECT toDate(event_ts) AS day, uniqExact(user_id) AS users
FROM xbench.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= toDateTime('2026-10-15 00:00:00', 'UTC') AND event_ts < toDateTime('2026-10-17 00:00:00', 'UTC')
GROUP BY day;

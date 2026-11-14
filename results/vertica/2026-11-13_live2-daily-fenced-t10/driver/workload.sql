-- @engine vertica
-- @set day1=2026-10-15
-- @set day3=2026-10-17
-- @set tenant=10
-- @query q2.daily.A answer=q2.daily oracle
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00'
GROUP BY event_ts::DATE;
-- @query q2.daily.L answer=q2.daily
SELECT day, SUM(vbitmap.bm_cardinality(payload)) AS users
FROM bitmap_live.daily_bitmap
WHERE tenant_id = 10 AND channel = 'web' AND day >= DATE '2026-10-15' AND day < DATE '2026-10-17'
GROUP BY day;

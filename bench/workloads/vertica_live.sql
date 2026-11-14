-- Vertica workload on the live projections of schema bitmap_live (scripts/live_index.sh): the daily
-- distinct users read from the sets that Vertica maintains on every load of events. The person
-- queries run from bench/workloads/vertica.sql and vertica_ids.sql with
-- --var index=bitmap_live.bitmap_index.
-- @engine vertica
-- @set day1=2026-10-15
-- @set day3=2026-10-17

-- @query q2.daily.A answer=q2.daily oracle
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = ${tenant} AND channel = 'web'
  AND event_ts >= TIMESTAMP '${day1} 00:00:00' AND event_ts < TIMESTAMP '${day3} 00:00:00'
GROUP BY event_ts::DATE;

-- @query q2.daily.L answer=q2.daily
SELECT day, SUM(vbitmap.bm_cardinality(payload)) AS users
FROM bitmap_live.daily_bitmap
WHERE tenant_id = ${tenant} AND channel = 'web' AND day >= DATE '${day1}' AND day < DATE '${day3}'
GROUP BY day;

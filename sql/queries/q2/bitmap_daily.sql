-- Q2 distinct web users per day, bitmap SQL: one stored set per (day, channel, chunk).
SELECT day, SUM(vbitmap.bm_cardinality(payload)) AS users
FROM bitmap_demo.daily_bitmap
WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person'
  AND channel = 'web' AND day >= DATE '2026-11-01' AND day < DATE '2026-11-03'
GROUP BY day;

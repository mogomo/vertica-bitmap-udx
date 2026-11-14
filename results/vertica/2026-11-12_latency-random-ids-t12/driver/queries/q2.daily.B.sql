SELECT day, SUM(vbitmap.bm_cardinality(payload)) AS users
FROM bitmap_demo.daily_bitmap
WHERE tenant_id = 12 AND snapshot_id = 1 AND domain = 'person'
  AND channel = 'web' AND day >= DATE '2026-10-15' AND day < DATE '2026-10-17'
GROUP BY day;

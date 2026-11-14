SELECT day, SUM(vbitmap.bm_cardinality(payload)) AS users
FROM bitmap_live.daily_bitmap
WHERE tenant_id = 10 AND channel = 'web' AND day >= DATE '2026-10-15' AND day < DATE '2026-10-17'
GROUP BY day;

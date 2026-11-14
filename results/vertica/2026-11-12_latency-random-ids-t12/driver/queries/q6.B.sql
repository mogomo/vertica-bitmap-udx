WITH s AS (
  SELECT day, chunk_id, payload FROM bitmap_demo.daily_bitmap
  WHERE tenant_id = 12 AND snapshot_id = 1 AND domain = 'person' AND channel = 'web'
    AND day >= DATE '2026-10-15' AND day < DATE '2026-10-22'
)
SELECT a.day || ' ' || b.day AS days, SUM(vbitmap.bm_and_cardinality(a.payload, b.payload)) AS users
FROM s a JOIN s b ON b.chunk_id = a.chunk_id AND b.day >= a.day
GROUP BY a.day, b.day
HAVING SUM(vbitmap.bm_and_cardinality(a.payload, b.payload)) > 0;

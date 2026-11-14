-- Q6 retention grid, bitmap SQL: intersection counts of the daily sets, chunk by chunk.
WITH s AS (
  SELECT day, chunk_id, payload FROM bitmap_demo.daily_bitmap
  WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person' AND channel = 'web'
)
SELECT a.day || ' ' || b.day AS days, SUM(vbitmap.bm_and_cardinality(a.payload, b.payload)) AS users
FROM s a JOIN s b ON b.chunk_id = a.chunk_id AND b.day >= a.day
GROUP BY a.day, b.day
HAVING SUM(vbitmap.bm_and_cardinality(a.payload, b.payload)) > 0;

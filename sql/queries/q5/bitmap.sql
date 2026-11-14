-- Q5 stale assets, explicit bitmap SQL: the cutoff is the union of the daily refresh buckets
-- before it (bucket names sort by date: refreshed_YYYY_MM_DD).
WITH k AS (
  SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
  WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'asset'
), refreshed AS (
  SELECT vbitmap.bm_union(chunk_id, payload) OVER (PARTITION BY chunk_id)
  FROM k WHERE predicate LIKE 'refreshed\_%' AND predicate < 'refreshed_2026_10_25'
), stale AS (
  SELECT a.chunk_id,
         vbitmap.bm_and(vbitmap.bm_and(a.payload, b.payload), vbitmap.bm_and(c.payload, r.payload)) AS payload
  FROM k a
  JOIN k b ON b.chunk_id = a.chunk_id AND b.predicate = 'deleted_false'
  JOIN k c ON c.chunk_id = a.chunk_id AND c.predicate = 'source_ERP_A'
  JOIN refreshed r ON r.chunk_id = a.chunk_id
  WHERE a.predicate = 'pii_true'
)
SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS asset_id FROM stale;

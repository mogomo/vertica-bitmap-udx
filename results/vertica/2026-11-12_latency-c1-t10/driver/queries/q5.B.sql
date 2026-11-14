WITH k AS (
  SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'asset'
), refreshed AS (
  SELECT vbitmap.bm_union(chunk_id, payload) OVER (PARTITION BY chunk_id)
  FROM k WHERE predicate LIKE 'refreshed\_%' AND predicate < 'refreshed_' || REPLACE('2026-10-25', '-', '_')
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

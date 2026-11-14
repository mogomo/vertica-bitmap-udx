-- Q4 devices, explicit bitmap SQL: four required sets intersected per chunk.
WITH k AS (
  SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
  WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'device'
), hot AS (
  SELECT a.chunk_id,
         vbitmap.bm_and(vbitmap.bm_and(a.payload, b.payload), vbitmap.bm_and(c.payload, d.payload)) AS payload
  FROM k a
  JOIN k b ON b.chunk_id = a.chunk_id AND b.predicate = 'zone_A'
  JOIN k c ON c.chunk_id = a.chunk_id AND c.predicate = 'temp_ge_800'
  JOIN k d ON d.chunk_id = a.chunk_id AND d.predicate = 'changes_gt_3'
  WHERE a.predicate = 'online_true'
)
SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS device_id FROM hot;

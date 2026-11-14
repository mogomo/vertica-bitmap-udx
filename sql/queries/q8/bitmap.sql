-- Q8 exclusion, explicit bitmap SQL: (country_IL AND topic_sports) ANDNOT topic_finance.
WITH k AS (
  SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
  WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person'
), x AS (
  SELECT a.chunk_id,
         vbitmap.bm_andnot(vbitmap.bm_and(a.payload, s.payload), COALESCE(f.payload, vbitmap.bm_empty())) AS payload
  FROM k a
  JOIN k s ON s.chunk_id = a.chunk_id AND s.predicate = 'topic_sports'
  LEFT JOIN k f ON f.chunk_id = a.chunk_id AND f.predicate = 'topic_finance'
  WHERE a.predicate = 'country_IL'
)
SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS entity_id FROM x;

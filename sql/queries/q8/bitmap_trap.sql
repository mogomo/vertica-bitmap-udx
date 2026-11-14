-- Q8 NULL trap, bitmap SQL: all ANDNOT suspended_true against the explicit suspended_false set.
WITH k AS (
  SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
  WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person'
)
SELECT (SELECT COALESCE(SUM(vbitmap.bm_cardinality(
                 vbitmap.bm_andnot(a.payload, COALESCE(t.payload, vbitmap.bm_empty())))), 0)
        FROM k a LEFT JOIN k t ON t.chunk_id = a.chunk_id AND t.predicate = 'suspended_true'
        WHERE a.predicate = 'all') AS complement,
       (SELECT COALESCE(SUM(vbitmap.bm_cardinality(payload)), 0) FROM k
        WHERE predicate = 'suspended_false') AS explicit;

WITH f AS (
  SELECT predicate, SUM(cnt) AS inter
  FROM (
    SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_sports', facets = 'topic_')
           OVER (PARTITION BY chunk_id)
    FROM bitmap_enc.index_zstd
    WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate LIKE 'topic\_%'
  ) t
  GROUP BY predicate
), s AS (
  SELECT cardinality AS n FROM bitmap_demo.bitmap_predicate
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate = 'topic_sports'
)
SELECT p.predicate, COALESCE(f.inter, 0) AS intersection, p.cardinality + s.n - COALESCE(f.inter, 0) AS union_size,
       ROUND(COALESCE(f.inter, 0) / (p.cardinality + s.n - COALESCE(f.inter, 0))::FLOAT, 4) AS jaccard
FROM bitmap_demo.bitmap_predicate p CROSS JOIN s LEFT JOIN f ON f.predicate = p.predicate
WHERE p.tenant_id = 10 AND p.snapshot_id = 1 AND p.domain = 'person'
  AND p.predicate LIKE 'topic\_%' AND p.predicate <> 'topic_sports';

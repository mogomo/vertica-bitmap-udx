WITH f AS (
  SELECT name AS predicate, SUM(cnt) AS inter
  FROM (
    SELECT vbitmap.bm_pair_count(k.predicate, a.payload, k.payload) OVER (PARTITION BEST)
    FROM bitmap_demo.bitmap_index k
    JOIN (SELECT chunk_id, payload FROM bitmap_demo.bitmap_index
          WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person' AND predicate = 'topic_sports') a
      ON a.chunk_id = k.chunk_id
    WHERE k.tenant_id = 20 AND k.snapshot_id = 1 AND k.domain = 'person' AND k.predicate LIKE 'topic\_%'
  ) t
  GROUP BY name
), s AS (
  SELECT cardinality AS n FROM bitmap_demo.bitmap_predicate
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person' AND predicate = 'topic_sports'
)
SELECT p.predicate, COALESCE(f.inter, 0) AS intersection, p.cardinality + s.n - COALESCE(f.inter, 0) AS union_size,
       ROUND(COALESCE(f.inter, 0) / (p.cardinality + s.n - COALESCE(f.inter, 0))::FLOAT, 4) AS jaccard
FROM bitmap_demo.bitmap_predicate p CROSS JOIN s LEFT JOIN f ON f.predicate = p.predicate
WHERE p.tenant_id = 20 AND p.snapshot_id = 1 AND p.domain = 'person'
  AND p.predicate LIKE 'topic\_%' AND p.predicate <> 'topic_sports';

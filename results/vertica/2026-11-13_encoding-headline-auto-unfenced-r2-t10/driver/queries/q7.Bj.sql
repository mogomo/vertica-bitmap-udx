SELECT o.predicate, o.inter AS intersection, o.size + s.n - o.inter AS union_size,
       ROUND(o.inter / (o.size + s.n - o.inter)::FLOAT, 4) AS jaccard
FROM (
  SELECT k.predicate,
         SUM(vbitmap.bm_cardinality(k.payload)) AS size,
         SUM(COALESCE(vbitmap.bm_and_cardinality(k.payload, a.payload), 0)) AS inter
  FROM bitmap_enc.index_auto k
  LEFT JOIN (SELECT chunk_id, payload FROM bitmap_enc.index_auto
             WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
               AND predicate = 'topic_sports') a ON a.chunk_id = k.chunk_id
  WHERE k.tenant_id = 10 AND k.snapshot_id = 1 AND k.domain = 'person'
    AND k.predicate LIKE 'topic\_%' AND k.predicate <> 'topic_sports'
  GROUP BY k.predicate
) o CROSS JOIN (
  SELECT SUM(vbitmap.bm_cardinality(payload)) AS n FROM bitmap_enc.index_auto
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate = 'topic_sports'
) s;

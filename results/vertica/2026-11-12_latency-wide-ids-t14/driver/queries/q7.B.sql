WITH k AS (
  SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 14 AND snapshot_id = 1 AND domain = 'person'
    AND predicate LIKE 'topic\_%'
), a AS (
  SELECT chunk_id, payload FROM k WHERE predicate = 'topic_sports'
), o AS (
  SELECT k.predicate,
         SUM(vbitmap.bm_cardinality(k.payload)) AS size,
         SUM(COALESCE(vbitmap.bm_and_cardinality(k.payload, a.payload), 0)) AS inter
  FROM k LEFT JOIN a ON a.chunk_id = k.chunk_id
  WHERE k.predicate <> 'topic_sports'
  GROUP BY k.predicate
)
SELECT predicate, inter AS intersection, size + (SELECT SUM(vbitmap.bm_cardinality(payload)) FROM a) - inter AS union_size,
       ROUND(inter / (size + (SELECT SUM(vbitmap.bm_cardinality(payload)) FROM a) - inter)::FLOAT, 4) AS jaccard
FROM o;

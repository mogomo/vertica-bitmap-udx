WITH t AS (
  SELECT DISTINCT topic, entity_id FROM bitmap_demo.user_interest
  WHERE tenant_id = 20 AND snapshot_id = 1
), a AS (
  SELECT entity_id FROM t WHERE topic = 'sports'
), o AS (
  SELECT t.topic, COUNT(*) AS size, SUM(CASE WHEN a.entity_id IS NULL THEN 0 ELSE 1 END) AS inter
  FROM t LEFT JOIN a ON a.entity_id = t.entity_id
  WHERE t.topic <> 'sports'
  GROUP BY t.topic
)
SELECT 'topic_' || topic AS predicate, inter AS intersection, size + (SELECT COUNT(*) FROM a) - inter AS union_size,
       ROUND(inter / (size + (SELECT COUNT(*) FROM a) - inter)::FLOAT, 4) AS jaccard
FROM o;

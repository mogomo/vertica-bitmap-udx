SELECT 'topic_' || t.topic AS predicate, t.inter AS intersection, t.size + s.n - t.inter AS union_size,
       ROUND(t.inter / (t.size + s.n - t.inter)::FLOAT, 4) AS jaccard
FROM (
  SELECT u.topic, COUNT(*) AS size, SUM(CASE WHEN a.entity_id IS NULL THEN 0 ELSE 1 END) AS inter
  FROM (SELECT DISTINCT topic, entity_id FROM bitmap_demo.user_interest
        WHERE tenant_id = 12 AND snapshot_id = 1 AND topic <> 'sports') u
  LEFT JOIN (SELECT DISTINCT entity_id FROM bitmap_demo.user_interest
             WHERE tenant_id = 12 AND snapshot_id = 1 AND topic = 'sports') a
    ON a.entity_id = u.entity_id
  GROUP BY u.topic
) t
CROSS JOIN (SELECT COUNT(DISTINCT entity_id) AS n FROM bitmap_demo.user_interest
            WHERE tenant_id = 12 AND snapshot_id = 1 AND topic = 'sports') s;

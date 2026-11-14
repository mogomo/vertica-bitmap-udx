SELECT concat('topic_', t.topic) AS predicate, t.inter AS intersection, t.size + s.n - t.inter AS union_size,
       round(t.inter / (t.size + s.n - t.inter), 4) AS jaccard
FROM (
  SELECT topic, uniqExact(entity_id) AS size,
         uniqExactIf(entity_id, entity_id IN (SELECT entity_id FROM xbench.user_interest
                                              WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports')) AS inter
  FROM xbench.user_interest
  WHERE tenant_id = 10 AND snapshot_id = 1 AND topic != 'sports'
  GROUP BY topic) AS t
CROSS JOIN (SELECT uniqExact(entity_id) AS n FROM xbench.user_interest
            WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports') AS s;

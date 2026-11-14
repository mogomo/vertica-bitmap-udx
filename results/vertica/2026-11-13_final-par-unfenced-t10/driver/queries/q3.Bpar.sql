SELECT name AS predicate, SUM(cnt) AS users
FROM (
  SELECT vbitmap.bm_pair_count(f.predicate, a.payload, f.payload) OVER (PARTITION BEST)
  FROM bitmap_demo.bitmap_index f
  JOIN (SELECT chunk_id, payload FROM (
          SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr =
                   'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
                 OVER (PARTITION BY chunk_id)
          FROM bitmap_demo.bitmap_index
          WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
            AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')) e) a
    ON a.chunk_id = f.chunk_id
  WHERE f.tenant_id = 10 AND f.snapshot_id = 1 AND f.domain = 'person' AND f.predicate LIKE 'topic\_%'
) t
GROUP BY name;

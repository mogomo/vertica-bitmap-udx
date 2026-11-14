SELECT people, age_known, CASE WHEN age_known > 0 THEN bit_sum END AS age_sum
FROM (
  SELECT COALESCE(SUM(CASE WHEN predicate = 'all' THEN cnt END), 0) AS people,
         COALESCE(SUM(CASE WHEN predicate = 'age_known' THEN cnt END), 0) AS age_known,
         COALESCE(SUM(CASE WHEN predicate LIKE 'age\_bit\_%'
                           THEN cnt * (1 << SPLIT_PART(predicate, '_', 3)::INT) END), 0) AS bit_sum
  FROM (
    SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS
             expr = 'country_IL & topic_sports - topic_finance', facets = '')
           OVER (PARTITION BY chunk_id)
    FROM bitmap_demo.bitmap_index
    WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
      AND (predicate IN ('country_IL', 'topic_sports', 'topic_finance', 'all', 'age_known')
           OR predicate LIKE 'age\_bit\_%')
  ) f
) t;

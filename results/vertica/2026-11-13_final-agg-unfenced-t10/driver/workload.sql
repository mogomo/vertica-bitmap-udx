-- @engine vertica
-- @set device_wm=2026-11-01 12:00:00
-- @set dsnap=1
-- @set index=bitmap_demo.bitmap_index
-- @set psnap=1
-- @set src=1
-- @set tenant=10
-- @query q8.sum.Bplus answer=q8.sum
SELECT COUNT(*) AS ids, SUM(entity_id) AS id_sum FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
) t;
-- @query q8.join.Bplus answer=q8.join
SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = 10 AND x.snapshot_id = 1 AND x.entity_id IN (
  SELECT entity_id FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
  ) t);
-- @query q8.agg.Bplus answer=q8.join
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

SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = 10 AND x.snapshot_id = 1 AND x.entity_id IN (
  SELECT entity_id FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_live.bitmap_index
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
  ) t);

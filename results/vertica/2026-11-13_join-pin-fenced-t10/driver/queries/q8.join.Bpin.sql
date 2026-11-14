SELECT members FROM (
  SELECT vbitmap.bm_pin(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance', name = 'q8')
         OVER ()
  FROM (SELECT chunk_id, predicate, payload FROM bitmap_demo.bitmap_index
        WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
          AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
        UNION ALL SELECT NULL, NULL, NULL) r
) p WHERE members < 0;
SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = 10 AND x.snapshot_id = 1
  AND vbitmap.bm_member(x.entity_id USING PARAMETERS name = 'q8');

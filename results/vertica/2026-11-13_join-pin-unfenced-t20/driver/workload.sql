-- @engine vertica
-- @set device_wm=2026-11-01 12:00:00
-- @set dsnap=1
-- @set index=bitmap_demo.bitmap_index
-- @set psnap=1
-- @set src=1
-- @set tenant=20
-- @query q8.join.Bplus answer=q8.join
SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = 20 AND x.snapshot_id = 1 AND x.entity_id IN (
  SELECT entity_id FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
  ) t);
-- @query q8.join.Bpin answer=q8.join
SELECT members FROM (
  SELECT vbitmap.bm_pin(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance', name = 'q8')
         OVER ()
  FROM (SELECT chunk_id, predicate, payload FROM bitmap_demo.bitmap_index
        WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
          AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
        UNION ALL SELECT NULL, NULL, NULL) r
) p WHERE members < 0;
SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = 20 AND x.snapshot_id = 1
  AND vbitmap.bm_member(x.entity_id USING PARAMETERS name = 'q8');

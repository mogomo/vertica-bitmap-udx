-- @engine clickhouse
-- @set bsnap=1
-- @set device_wm=2026-11-01 12:00:00
-- @set ptable=xbench.person_bitmap
-- @set src=1
-- @set tenant=10
-- @query q8.join.N answer=q8.join oracle
SELECT count() AS people, count(age) AS age_known, sum(age) AS age_sum
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1 AND entity_id IN (
  SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = 10 AND snapshot_id = 1 AND country = 'IL'
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports')
    AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                          WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'finance'));
-- @query q8.join.C answer=q8.join
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT count() AS people, count(age) AS age_known, sum(age) AS age_sum
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1 AND bitmapContains(bitmapAndnot(bitmapAnd(a, s), f), entity_id);
-- @query q8.join.Cin answer=q8.join
SELECT count() AS people, count(age) AS age_known, sum(age) AS age_sum
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1 AND entity_id IN (
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f))));

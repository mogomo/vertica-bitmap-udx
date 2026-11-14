-- @engine clickhouse
-- @set bsnap=1
-- @set device_wm=2026-11-01 12:00:00
-- @set ptable=xbench.person_bitmap
-- @set src=1
-- @set tenant=10
-- @query q1.ids.sum.N answer=q1.ids.sum oracle
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
  SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = 10 AND snapshot_id = 1
    AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = 10 AND snapshot_id = 1 AND topic IN ('sports', 'finance')));
-- @query q1.ids.sum.C answer=q1.ids.sum
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f)))) AS entity_id);
-- @query q4.sum.N answer=q4.sum oracle
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
  SELECT device_id AS entity_id
  FROM xbench.device_state
  WHERE tenant_id = 10 AND snapshot_id = 1
    AND observed_at > toDateTime('2026-11-01 12:00:00', 'UTC') - INTERVAL 30 MINUTE AND observed_at <= toDateTime('2026-11-01 12:00:00', 'UTC')
    AND online = true AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3);
-- @query q4.sum.C answer=q4.sum
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'online_true') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'zone_A') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'temp_ge_800') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'changes_gt_3') AS d
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)))) AS entity_id);
-- @query q8.sum.N answer=q8.sum oracle
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
  SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = 10 AND snapshot_id = 1 AND country = 'IL'
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports')
    AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                          WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'finance'));
-- @query q8.sum.C answer=q8.sum
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f))) AS entity_id);
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

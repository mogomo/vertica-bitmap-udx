-- @engine clickhouse
-- @set bsnap=1
-- @set day1=2026-10-15
-- @set day3=2026-10-17
-- @set device_wm=2026-11-01 12:00:00
-- @set ptable=xbench.live_bitmap
-- @set src=1
-- @set tenant=10
-- @query q1.count.N answer=q1.count oracle
SELECT count() AS audience
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1
  AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
  AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                    WHERE tenant_id = 10 AND snapshot_id = 1 AND topic IN ('sports', 'finance'));
-- @query q1.count.C answer=q1.count
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT bitmapCardinality(bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f))) AS audience;
-- @query q3.N answer=q3 oracle
SELECT concat('topic_', topic) AS predicate, uniqExact(entity_id) AS users
FROM xbench.user_interest
WHERE tenant_id = 10 AND snapshot_id = 1
  AND entity_id IN (
    SELECT entity_id FROM xbench.user_profile
    WHERE tenant_id = 10 AND snapshot_id = 1
      AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
      AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                        WHERE tenant_id = 10 AND snapshot_id = 1 AND topic IN ('sports', 'finance')))
GROUP BY topic;
-- @query q3.C answer=q3
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f,
     bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f)) AS cohort
SELECT predicate, bitmapAndCardinality(cohort, bm) AS users
FROM xbench.live_bitmap
WHERE tenant_id = 10 AND snapshot_id = 1 AND startsWith(predicate, 'topic_') AND users > 0;
-- @query q8.N answer=q8 oracle
SELECT entity_id
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1 AND country = 'IL'
  AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                    WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports')
  AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                        WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'finance');
-- @query q8.C answer=q8
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.live_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f))) AS entity_id;

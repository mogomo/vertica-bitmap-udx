-- @engine clickhouse
-- @set bsnap=1
-- @set day1=2026-10-15
-- @set day3=2026-10-17
-- @set device_wm=2026-11-01 12:00:00
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
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT bitmapCardinality(bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f))) AS audience;
-- @query q1.ids.N answer=q1.ids oracle
SELECT entity_id
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1
  AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
  AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                    WHERE tenant_id = 10 AND snapshot_id = 1 AND topic IN ('sports', 'finance'));
-- @query q1.ids.C answer=q1.ids
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f)))) AS entity_id;
-- @query q2.daily.N answer=q2.daily oracle
SELECT toDate(event_ts) AS day, uniqExact(user_id) AS users
FROM xbench.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= toDateTime('2026-10-15 00:00:00', 'UTC') AND event_ts < toDateTime('2026-10-17 00:00:00', 'UTC')
GROUP BY day;
-- @query q2.daily.C answer=q2.daily
SELECT day, groupBitmapMerge(bm) AS users
FROM xbench.daily_bitmap
WHERE tenant_id = 10 AND snapshot_id = 1 AND channel = 'web'
  AND day >= toDate('2026-10-15') AND day < toDate('2026-10-17')
GROUP BY day;
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
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f,
     bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f)) AS cohort
SELECT predicate, bitmapAndCardinality(cohort, bm) AS users
FROM xbench.person_bitmap
WHERE tenant_id = 10 AND snapshot_id = 1 AND startsWith(predicate, 'topic_') AND users > 0;
-- @query q4.N answer=q4 oracle
SELECT device_id
FROM xbench.device_state
WHERE tenant_id = 10 AND snapshot_id = 1
  AND observed_at > toDateTime('2026-11-01 12:00:00', 'UTC') - INTERVAL 30 MINUTE AND observed_at <= toDateTime('2026-11-01 12:00:00', 'UTC')
  AND online = true AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;
-- @query q4.C answer=q4
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'online_true') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'zone_A') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'temp_ge_800') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'changes_gt_3') AS d
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)))) AS device_id;
-- @query q7.N answer=q7 oracle
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
-- @query q7.C answer=q7
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS sp,
     bitmapCardinality(sp) AS n
SELECT predicate, bitmapAndCardinality(bm, sp) AS intersection,
       bitmapCardinality(bm) + n - intersection AS union_size,
       round(intersection / union_size, 4) AS jaccard
FROM xbench.person_bitmap
WHERE tenant_id = 10 AND snapshot_id = 1 AND startsWith(predicate, 'topic_') AND predicate != 'topic_sports';
-- @query q8.N answer=q8 oracle
SELECT entity_id
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1 AND country = 'IL'
  AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                    WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports')
  AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                        WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'finance');
-- @query q8.C answer=q8
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f))) AS entity_id;

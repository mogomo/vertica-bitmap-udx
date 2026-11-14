-- ClickHouse workload: the six headline queries of D13 (Q1 count and IDs, Q2 daily, Q3 facets,
-- Q4 devices, Q7 overlap ranking, Q8 IDs) on the same data as bench/workloads/vertica.sql.
--   N   native ClickHouse SQL on the source tables (oracle inside this workload)
--   C   ClickHouse bitmaps: one groupBitmap state per predicate / (day, channel), built by
--       bench/ch.sh build from the same family definitions; bitmapAnd / Or / Andnot /
--       AndCardinality / Cardinality / ToArray
-- Answer keys equal the Vertica workload's, so bench/driver.py --expect=<Vertica check.csv> checks
-- every answer against Vertica's native oracle as well.
-- @engine clickhouse
-- @set src=1
-- @set ptable=xbench.person_bitmap
-- @set bsnap=1
-- @set day1=2026-10-15
-- @set day3=2026-10-17
-- @set device_wm=2026-11-01 12:00:00

-- ==== Q1 audience: IL, age 25 to 54, consent, not suspended, sports or finance ====

-- @query q1.count.N answer=q1.count oracle
SELECT count() AS audience
FROM xbench.user_profile
WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
  AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
  AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                    WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic IN ('sports', 'finance'));

-- @query q1.count.C answer=q1.count
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT bitmapCardinality(bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f))) AS audience;

-- @query q1.ids.N answer=q1.ids oracle
SELECT entity_id
FROM xbench.user_profile
WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
  AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
  AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                    WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic IN ('sports', 'finance'));

-- @query q1.ids.C answer=q1.ids
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f)))) AS entity_id;

-- ==== Q2 daily distinct web users, two days ====

-- @query q2.daily.N answer=q2.daily oracle
SELECT toDate(event_ts) AS day, uniqExact(user_id) AS users
FROM xbench.event_log
WHERE tenant_id = ${tenant} AND channel = 'web'
  AND event_ts >= toDateTime('${day1} 00:00:00', 'UTC') AND event_ts < toDateTime('${day3} 00:00:00', 'UTC')
GROUP BY day;

-- @query q2.daily.C answer=q2.daily
SELECT day, groupBitmapMerge(bm) AS users
FROM xbench.daily_bitmap
WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND channel = 'web'
  AND day >= toDate('${day1}') AND day < toDate('${day3}')
GROUP BY day;

-- ==== Q3 users per topic inside the Q1 audience ====

-- @query q3.N answer=q3 oracle
SELECT concat('topic_', topic) AS predicate, uniqExact(entity_id) AS users
FROM xbench.user_interest
WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
  AND entity_id IN (
    SELECT entity_id FROM xbench.user_profile
    WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
      AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
      AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                        WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic IN ('sports', 'finance')))
GROUP BY topic;

-- @query q3.C answer=q3
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f,
     bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f)) AS cohort
SELECT predicate, bitmapAndCardinality(cohort, bm) AS users
FROM ${ptable}
WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND startsWith(predicate, 'topic_') AND users > 0;

-- ==== Q4 devices: online, zone A, at least 80.0 C, more than 3 changes (IDs) ====

-- @query q4.N answer=q4 oracle
SELECT device_id
FROM xbench.device_state
WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
  AND observed_at > toDateTime('${device_wm}', 'UTC') - INTERVAL 30 MINUTE AND observed_at <= toDateTime('${device_wm}', 'UTC')
  AND online = true AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;

-- @query q4.C answer=q4
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'online_true') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'zone_A') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'temp_ge_800') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'changes_gt_3') AS d
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)))) AS device_id;

-- ==== Q7 overlap ranking: Jaccard index of sports with every other topic ====

-- @query q7.N answer=q7 oracle
SELECT concat('topic_', t.topic) AS predicate, t.inter AS intersection, t.size + s.n - t.inter AS union_size,
       round(t.inter / (t.size + s.n - t.inter), 4) AS jaccard
FROM (
  SELECT topic, uniqExact(entity_id) AS size,
         uniqExactIf(entity_id, entity_id IN (SELECT entity_id FROM xbench.user_interest
                                              WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'sports')) AS inter
  FROM xbench.user_interest
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic != 'sports'
  GROUP BY topic) AS t
CROSS JOIN (SELECT uniqExact(entity_id) AS n FROM xbench.user_interest
            WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'sports') AS s;

-- @query q7.C answer=q7
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS sp,
     bitmapCardinality(sp) AS n
SELECT predicate, bitmapAndCardinality(bm, sp) AS intersection,
       bitmapCardinality(bm) + n - intersection AS union_size,
       round(intersection / union_size, 4) AS jaccard
FROM ${ptable}
WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND startsWith(predicate, 'topic_') AND predicate != 'topic_sports';

-- ==== Q8 IL users interested in sports and not in finance (IDs) ====

-- @query q8.N answer=q8 oracle
SELECT entity_id
FROM xbench.user_profile
WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND country = 'IL'
  AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                    WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'sports')
  AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                        WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'finance');

-- @query q8.C answer=q8
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f))) AS entity_id;

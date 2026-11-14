-- ClickHouse workload of the ID-list tests (chain 14); the counterpart of
-- bench/workloads/vertica_ids.sql, same answers (bench/driver.py --expect checks them against
-- Vertica's native oracle).
--   ids    one row per ID (arrayJoin(bitmapToArray(...))): native SQL (N) and bitmaps (C)
--   sum    the list consumed inside the engine: count() and sum of the IDs
--   join   the list joined to the profile table (bitmapContains on the profile rows; the IN
--          subquery form of the same question is q8.join.Cin; the faster one is reported)
--   agg    the same three numbers from set counts alone, no join: the age stored as bit-sliced
--          sets (bench/ch.sh build-bits), the counterpart of q8.agg.Bplus
--   save   the audience kept in the database: as a set (one groupBitmap state) or as a table of
--          IDs. Target tables: bench/engines/clickhouse/idtests.sql. An INSERT returns no rows.
-- ptable names the table that holds the person sets (default: the built sets; the sets kept by a
-- materialized view: xbench.live_bitmap).
-- @engine clickhouse
-- @set src=1
-- @set bsnap=1
-- @set ptable=xbench.person_bitmap
-- @set device_wm=2026-11-01 12:00:00

-- ==== one row per ID ====

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

-- @query q4.N answer=q4 oracle
SELECT device_id AS entity_id
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

-- ==== the list consumed inside the engine ====

-- @query q1.ids.sum.N answer=q1.ids.sum oracle
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
  SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
    AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic IN ('sports', 'finance')));

-- @query q1.ids.sum.C answer=q1.ids.sum
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'age_25_54') AS b,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'consent_true') AS c,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'suspended_false') AS d,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)), bitmapOr(s, f)))) AS entity_id);

-- @query q4.sum.N answer=q4.sum oracle
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
  SELECT device_id AS entity_id
  FROM xbench.device_state
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
    AND observed_at > toDateTime('${device_wm}', 'UTC') - INTERVAL 30 MINUTE AND observed_at <= toDateTime('${device_wm}', 'UTC')
    AND online = true AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3);

-- @query q4.sum.C answer=q4.sum
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'online_true') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'zone_A') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'temp_ge_800') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'changes_gt_3') AS d
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)))) AS entity_id);

-- @query q8.sum.N answer=q8.sum oracle
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
  SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND country = 'IL'
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'sports')
    AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                          WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'finance'));

-- @query q8.sum.C answer=q8.sum
SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f))) AS entity_id);

-- ==== the list joined to the profile table ====

-- @query q8.join.N answer=q8.join oracle
SELECT count() AS people, count(age) AS age_known, sum(age) AS age_sum
FROM xbench.user_profile
WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND entity_id IN (
  SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND country = 'IL'
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'sports')
    AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                          WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'finance'));

-- @query q8.join.C answer=q8.join
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT count() AS people, count(age) AS age_known, sum(age) AS age_sum
FROM xbench.user_profile
WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND bitmapContains(bitmapAndnot(bitmapAnd(a, s), f), entity_id);

-- @query q8.join.Cin answer=q8.join
SELECT count() AS people, count(age) AS age_known, sum(age) AS age_sum
FROM xbench.user_profile
WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND entity_id IN (
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f))));

-- ==== the same totals without a join: bit-sliced sets ====

-- @query q8.agg.C answer=q8.join
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f,
     bitmapAndnot(bitmapAnd(a, s), f) AS aud
SELECT bitmapCardinality(aud) AS people,
       sumIf(bitmapAndCardinality(aud, bm), predicate = 'age_known') AS age_known,
       sumIf(bitmapAndCardinality(aud, bm) * bitShiftLeft(toUInt64(1), toUInt8OrZero(substring(predicate, 9))), startsWith(predicate, 'age_bit_')) AS age_sum
FROM (SELECT predicate, groupBitmapMergeState(bm) AS bm FROM ${ptable}
      WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND (predicate = 'age_known' OR startsWith(predicate, 'age_bit_'))
      GROUP BY predicate);

-- ==== the audience kept in the database ====

-- @query q8.save.set.C answer=q8.save.set
INSERT INTO xbench.saved_set (audience, bm)
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT 'q8', bitmapAndnot(bitmapAnd(a, s), f);

-- @query q8.save.ids.N answer=q8.save.ids
INSERT INTO xbench.saved_ids (audience, entity_id)
SELECT 'q8', entity_id FROM (
  SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND country = 'IL'
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'sports')
    AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                          WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'finance'));

-- @query q8.save.ids.C answer=q8.save.ids
INSERT INTO xbench.saved_ids (audience, entity_id)
WITH (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM ${ptable} WHERE tenant_id = ${tenant} AND snapshot_id = ${bsnap} AND predicate = 'topic_finance') AS f
SELECT 'q8', arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f)));

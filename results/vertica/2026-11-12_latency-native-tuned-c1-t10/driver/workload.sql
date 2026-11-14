-- @engine vertica
-- @set asnap=1
-- @set day1=2026-10-15
-- @set day3=2026-10-17
-- @set device_wm=2026-11-01 12:00:00
-- @set dsnap=1
-- @set grid1=2026-10-15
-- @set grid8=2026-10-22
-- @set psnap=1
-- @set q5_cut=2026-10-25
-- @set q5_expr=refreshed_2026_09_01 | refreshed_2026_09_02 | refreshed_2026_09_03 | refreshed_2026_09_04 | refreshed_2026_09_05 | refreshed_2026_09_06 | refreshed_2026_09_07 | refreshed_2026_09_08 | refreshed_2026_09_09 | refreshed_2026_09_10 | refreshed_2026_09_11 | refreshed_2026_09_12 | refreshed_2026_09_13 | refreshed_2026_09_14 | refreshed_2026_09_15 | refreshed_2026_09_16 | refreshed_2026_09_17 | refreshed_2026_09_18 | refreshed_2026_09_19 | refreshed_2026_09_20 | refreshed_2026_09_21 | refreshed_2026_09_22 | refreshed_2026_09_23 | refreshed_2026_09_24 | refreshed_2026_09_25 | refreshed_2026_09_26 | refreshed_2026_09_27 | refreshed_2026_09_28 | refreshed_2026_09_29 | refreshed_2026_09_30 | refreshed_2026_10_01 | refreshed_2026_10_02 | refreshed_2026_10_03 | refreshed_2026_10_04 | refreshed_2026_10_05 | refreshed_2026_10_06 | refreshed_2026_10_07 | refreshed_2026_10_08 | refreshed_2026_10_09 | refreshed_2026_10_10 | refreshed_2026_10_11 | refreshed_2026_10_12 | refreshed_2026_10_13 | refreshed_2026_10_14 | refreshed_2026_10_15 | refreshed_2026_10_16 | refreshed_2026_10_17 | refreshed_2026_10_18 | refreshed_2026_10_19 | refreshed_2026_10_20 | refreshed_2026_10_21 | refreshed_2026_10_22 | refreshed_2026_10_23 | refreshed_2026_10_24
-- @set q5_in='refreshed_2026_09_01', 'refreshed_2026_09_02', 'refreshed_2026_09_03', 'refreshed_2026_09_04', 'refreshed_2026_09_05', 'refreshed_2026_09_06', 'refreshed_2026_09_07', 'refreshed_2026_09_08', 'refreshed_2026_09_09', 'refreshed_2026_09_10', 'refreshed_2026_09_11', 'refreshed_2026_09_12', 'refreshed_2026_09_13', 'refreshed_2026_09_14', 'refreshed_2026_09_15', 'refreshed_2026_09_16', 'refreshed_2026_09_17', 'refreshed_2026_09_18', 'refreshed_2026_09_19', 'refreshed_2026_09_20', 'refreshed_2026_09_21', 'refreshed_2026_09_22', 'refreshed_2026_09_23', 'refreshed_2026_09_24', 'refreshed_2026_09_25', 'refreshed_2026_09_26', 'refreshed_2026_09_27', 'refreshed_2026_09_28', 'refreshed_2026_09_29', 'refreshed_2026_09_30', 'refreshed_2026_10_01', 'refreshed_2026_10_02', 'refreshed_2026_10_03', 'refreshed_2026_10_04', 'refreshed_2026_10_05', 'refreshed_2026_10_06', 'refreshed_2026_10_07', 'refreshed_2026_10_08', 'refreshed_2026_10_09', 'refreshed_2026_10_10', 'refreshed_2026_10_11', 'refreshed_2026_10_12', 'refreshed_2026_10_13', 'refreshed_2026_10_14', 'refreshed_2026_10_15', 'refreshed_2026_10_16', 'refreshed_2026_10_17', 'refreshed_2026_10_18', 'refreshed_2026_10_19', 'refreshed_2026_10_20', 'refreshed_2026_10_21', 'refreshed_2026_10_22', 'refreshed_2026_10_23', 'refreshed_2026_10_24'
-- @set src=1
-- @set tenant=10
-- @query q1.count.A answer=q1.count oracle
SELECT COUNT(*) AS audience
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
  AND p.consent IS TRUE AND p.suspended IS FALSE
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.user_interest i
    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
      AND i.entity_id = p.entity_id AND i.topic IN ('sports', 'finance'));
-- @query q1.ids.A answer=q1.ids oracle
SELECT p.entity_id
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
  AND p.consent IS TRUE AND p.suspended IS FALSE
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.user_interest i
    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
      AND i.entity_id = p.entity_id AND i.topic IN ('sports', 'finance'));
-- @query q2.A answer=q2 oracle
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00';
-- @query q2.daily.A answer=q2.daily oracle
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00'
GROUP BY 1;
-- @query q2b.A answer=q2b oracle
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel IN ('web', 'app')
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00';
-- @query q3.A answer=q3 oracle
SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_demo.user_interest i
WHERE i.tenant_id = 10 AND i.snapshot_id = 1
  AND i.entity_id IN (
    SELECT p.entity_id FROM bitmap_demo.user_profile p
    WHERE p.tenant_id = 10 AND p.snapshot_id = 1
      AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
      AND p.consent IS TRUE AND p.suspended IS FALSE
      AND EXISTS (
        SELECT 1 FROM bitmap_demo.user_interest j
        WHERE j.tenant_id = p.tenant_id AND j.snapshot_id = p.snapshot_id
          AND j.entity_id = p.entity_id AND j.topic IN ('sports', 'finance')))
GROUP BY 1;
-- @query q3d.A answer=q3d oracle
SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_demo.user_interest i
JOIN bitmap_demo.user_profile p
  ON p.tenant_id = i.tenant_id AND p.snapshot_id = i.snapshot_id AND p.entity_id = i.entity_id
WHERE i.tenant_id = 10 AND i.snapshot_id = 1
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54 AND p.consent IS TRUE AND p.suspended IS FALSE
GROUP BY 1;
-- @query q4.A answer=q4 oracle
SELECT device_id
FROM bitmap_demo.device_state
WHERE tenant_id = 10 AND snapshot_id = 1
  AND observed_at > TIMESTAMPADD('minute', -30, '2026-11-01 12:00:00'::TIMESTAMP) AND observed_at <= '2026-11-01 12:00:00'::TIMESTAMP
  AND online IS TRUE AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;
-- @query q5.A answer=q5 oracle
SELECT a.asset_id
FROM bitmap_demo.asset_state a
WHERE a.tenant_id = 10 AND a.snapshot_id = 1
  AND a.contains_pii IS TRUE AND a.deleted IS FALSE
  AND a.refreshed_at < TIMESTAMP '2026-10-25 00:00:00'
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.asset_source s
    WHERE s.tenant_id = a.tenant_id AND s.snapshot_id = a.snapshot_id
      AND s.asset_id = a.asset_id AND s.source = 'ERP_A');
-- @query q6.A answer=q6 oracle
WITH d AS (
  SELECT DISTINCT event_ts::DATE AS day, user_id
  FROM bitmap_demo.event_log
  WHERE tenant_id = 10 AND channel = 'web'
    AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-22 00:00:00'
)
SELECT a.day || ' ' || b.day AS days, COUNT(*) AS users
FROM d a JOIN d b ON b.user_id = a.user_id AND b.day >= a.day
GROUP BY a.day, b.day;
-- @query q6.At answer=q6
SELECT a.day || ' ' || b.day AS days, COUNT(*) AS users
FROM (SELECT DISTINCT event_ts::DATE AS day, user_id FROM bitmap_demo.event_log
      WHERE tenant_id = 10 AND channel = 'web'
        AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-22 00:00:00') a
JOIN (SELECT DISTINCT event_ts::DATE AS day, user_id FROM bitmap_demo.event_log
      WHERE tenant_id = 10 AND channel = 'web'
        AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-22 00:00:00') b
  ON b.user_id = a.user_id AND b.day >= a.day
GROUP BY a.day, b.day;
-- @query q7.A answer=q7 oracle
WITH t AS (
  SELECT DISTINCT topic, entity_id FROM bitmap_demo.user_interest
  WHERE tenant_id = 10 AND snapshot_id = 1
), a AS (
  SELECT entity_id FROM t WHERE topic = 'sports'
), o AS (
  SELECT t.topic, COUNT(*) AS size, SUM(CASE WHEN a.entity_id IS NULL THEN 0 ELSE 1 END) AS inter
  FROM t LEFT JOIN a ON a.entity_id = t.entity_id
  WHERE t.topic <> 'sports'
  GROUP BY t.topic
)
SELECT 'topic_' || topic AS predicate, inter AS intersection, size + (SELECT COUNT(*) FROM a) - inter AS union_size,
       ROUND(inter / (size + (SELECT COUNT(*) FROM a) - inter)::FLOAT, 4) AS jaccard
FROM o;
-- @query q7.At answer=q7
SELECT 'topic_' || t.topic AS predicate, t.inter AS intersection, t.size + s.n - t.inter AS union_size,
       ROUND(t.inter / (t.size + s.n - t.inter)::FLOAT, 4) AS jaccard
FROM (
  SELECT u.topic, COUNT(*) AS size, SUM(CASE WHEN a.entity_id IS NULL THEN 0 ELSE 1 END) AS inter
  FROM (SELECT DISTINCT topic, entity_id FROM bitmap_demo.user_interest
        WHERE tenant_id = 10 AND snapshot_id = 1 AND topic <> 'sports') u
  LEFT JOIN (SELECT DISTINCT entity_id FROM bitmap_demo.user_interest
             WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports') a
    ON a.entity_id = u.entity_id
  GROUP BY u.topic
) t
CROSS JOIN (SELECT COUNT(DISTINCT entity_id) AS n FROM bitmap_demo.user_interest
            WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports') s;
-- @query q8.A answer=q8 oracle
SELECT p.entity_id
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1 AND p.country = 'IL'
  AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
              WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                AND i.entity_id = p.entity_id AND i.topic = 'sports')
  AND NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                  WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                    AND i.entity_id = p.entity_id AND i.topic = 'finance');
-- @query q8trap.A answer=q8trap oracle
SELECT SUM(CASE WHEN suspended IS TRUE THEN 0 ELSE 1 END) AS complement,
       SUM(CASE WHEN suspended IS FALSE THEN 1 ELSE 0 END) AS explicit
FROM bitmap_demo.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1;

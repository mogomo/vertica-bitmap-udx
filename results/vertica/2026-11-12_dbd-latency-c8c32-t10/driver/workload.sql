-- @engine vertica
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
-- @query q1.count.D answer=q1.count
SELECT COUNT(*) AS audience
FROM bitmap_dbd.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
  AND p.consent IS TRUE AND p.suspended IS FALSE
  AND EXISTS (
    SELECT 1 FROM bitmap_dbd.user_interest i
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
-- @query q1.ids.D answer=q1.ids
SELECT p.entity_id
FROM bitmap_dbd.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
  AND p.consent IS TRUE AND p.suspended IS FALSE
  AND EXISTS (
    SELECT 1 FROM bitmap_dbd.user_interest i
    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
      AND i.entity_id = p.entity_id AND i.topic IN ('sports', 'finance'));
-- @query q2.A answer=q2 oracle
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00';
-- @query q2.D answer=q2
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_dbd.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00';
-- @query q2.daily.A answer=q2.daily oracle
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00'
GROUP BY 1;
-- @query q2.daily.D answer=q2.daily
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_dbd.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00'
GROUP BY 1;
-- @query q2b.A answer=q2b oracle
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel IN ('web', 'app')
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00';
-- @query q2b.D answer=q2b
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_dbd.event_log
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
-- @query q3.D answer=q3
SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_dbd.user_interest i
WHERE i.tenant_id = 10 AND i.snapshot_id = 1
  AND i.entity_id IN (
    SELECT p.entity_id FROM bitmap_dbd.user_profile p
    WHERE p.tenant_id = 10 AND p.snapshot_id = 1
      AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
      AND p.consent IS TRUE AND p.suspended IS FALSE
      AND EXISTS (
        SELECT 1 FROM bitmap_dbd.user_interest j
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
-- @query q3d.D answer=q3d
SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_dbd.user_interest i
JOIN bitmap_dbd.user_profile p
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
-- @query q4.D answer=q4
SELECT device_id
FROM bitmap_dbd.device_state
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
-- @query q5.D answer=q5
SELECT a.asset_id
FROM bitmap_dbd.asset_state a
WHERE a.tenant_id = 10 AND a.snapshot_id = 1
  AND a.contains_pii IS TRUE AND a.deleted IS FALSE
  AND a.refreshed_at < TIMESTAMP '2026-10-25 00:00:00'
  AND EXISTS (
    SELECT 1 FROM bitmap_dbd.asset_source s
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
-- @query q6.D answer=q6
WITH d AS (
  SELECT DISTINCT event_ts::DATE AS day, user_id
  FROM bitmap_dbd.event_log
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
-- @query q6.Dt answer=q6
SELECT a.day || ' ' || b.day AS days, COUNT(*) AS users
FROM (SELECT DISTINCT event_ts::DATE AS day, user_id FROM bitmap_dbd.event_log
      WHERE tenant_id = 10 AND channel = 'web'
        AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-22 00:00:00') a
JOIN (SELECT DISTINCT event_ts::DATE AS day, user_id FROM bitmap_dbd.event_log
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
-- @query q7.Dt answer=q7
SELECT 'topic_' || t.topic AS predicate, t.inter AS intersection, t.size + s.n - t.inter AS union_size,
       ROUND(t.inter / (t.size + s.n - t.inter)::FLOAT, 4) AS jaccard
FROM (
  SELECT u.topic, COUNT(*) AS size, SUM(CASE WHEN a.entity_id IS NULL THEN 0 ELSE 1 END) AS inter
  FROM (SELECT DISTINCT topic, entity_id FROM bitmap_dbd.user_interest
        WHERE tenant_id = 10 AND snapshot_id = 1 AND topic <> 'sports') u
  LEFT JOIN (SELECT DISTINCT entity_id FROM bitmap_dbd.user_interest
             WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports') a
    ON a.entity_id = u.entity_id
  GROUP BY u.topic
) t
CROSS JOIN (SELECT COUNT(DISTINCT entity_id) AS n FROM bitmap_dbd.user_interest
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
-- @query q8.D answer=q8
SELECT p.entity_id
FROM bitmap_dbd.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1 AND p.country = 'IL'
  AND EXISTS (SELECT 1 FROM bitmap_dbd.user_interest i
              WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                AND i.entity_id = p.entity_id AND i.topic = 'sports')
  AND NOT EXISTS (SELECT 1 FROM bitmap_dbd.user_interest i
                  WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                    AND i.entity_id = p.entity_id AND i.topic = 'finance');
-- @query q8trap.A answer=q8trap oracle
SELECT SUM(CASE WHEN suspended IS TRUE THEN 0 ELSE 1 END) AS complement,
       SUM(CASE WHEN suspended IS FALSE THEN 1 ELSE 0 END) AS explicit
FROM bitmap_demo.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1;
-- @query q8trap.D answer=q8trap
SELECT SUM(CASE WHEN suspended IS TRUE THEN 0 ELSE 1 END) AS complement,
       SUM(CASE WHEN suspended IS FALSE THEN 1 ELSE 0 END) AS explicit
FROM bitmap_dbd.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1;

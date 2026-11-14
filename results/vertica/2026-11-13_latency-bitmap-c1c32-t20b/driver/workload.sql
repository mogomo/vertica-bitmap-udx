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
-- @set tenant=20
-- @query q1.count.A answer=q1.count oracle
SELECT COUNT(*) AS audience
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 20 AND p.snapshot_id = 1
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
  AND p.consent IS TRUE AND p.suspended IS FALSE
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.user_interest i
    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
      AND i.entity_id = p.entity_id AND i.topic IN ('sports', 'finance'));
-- @query q1.count.Bplus answer=q1.count
SELECT COALESCE(SUM(cnt), 0) AS audience
FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')
) t;
-- @query q1.ids.A answer=q1.ids oracle
SELECT p.entity_id
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 20 AND p.snapshot_id = 1
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
  AND p.consent IS TRUE AND p.suspended IS FALSE
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.user_interest i
    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
      AND i.entity_id = p.entity_id AND i.topic IN ('sports', 'finance'));
-- @query q1.ids.Bplus answer=q1.ids
SELECT entity_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')
) t;
-- @query q2.daily.A answer=q2.daily oracle
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 20 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00'
GROUP BY 1;
-- @query q2.daily.B answer=q2.daily
SELECT day, SUM(vbitmap.bm_cardinality(payload)) AS users
FROM bitmap_demo.daily_bitmap
WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
  AND channel = 'web' AND day >= DATE '2026-10-15' AND day < DATE '2026-10-17'
GROUP BY day;
-- @query q3.A answer=q3 oracle
SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_demo.user_interest i
WHERE i.tenant_id = 20 AND i.snapshot_id = 1
  AND i.entity_id IN (
    SELECT p.entity_id FROM bitmap_demo.user_profile p
    WHERE p.tenant_id = 20 AND p.snapshot_id = 1
      AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
      AND p.consent IS TRUE AND p.suspended IS FALSE
      AND EXISTS (
        SELECT 1 FROM bitmap_demo.user_interest j
        WHERE j.tenant_id = p.tenant_id AND j.snapshot_id = p.snapshot_id
          AND j.entity_id = p.entity_id AND j.topic IN ('sports', 'finance')))
GROUP BY 1;
-- @query q3.Bplus answer=q3
SELECT predicate, SUM(cnt) AS users
FROM (
  SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS
           expr = 'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)',
           facets = 'topic_')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
    AND (predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false') OR predicate LIKE 'topic\_%')
) t
GROUP BY predicate;
-- @query q4.A answer=q4 oracle
SELECT device_id
FROM bitmap_demo.device_state
WHERE tenant_id = 20 AND snapshot_id = 1
  AND observed_at > TIMESTAMPADD('minute', -30, '2026-11-01 12:00:00'::TIMESTAMP) AND observed_at <= '2026-11-01 12:00:00'::TIMESTAMP
  AND online IS TRUE AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;
-- @query q4.Bplus answer=q4
SELECT entity_id AS device_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'online_true & zone_A & temp_ge_800 & changes_gt_3')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'device'
    AND predicate IN ('online_true', 'zone_A', 'temp_ge_800', 'changes_gt_3')
) t;
-- @query q7.A answer=q7 oracle
WITH t AS (
  SELECT DISTINCT topic, entity_id FROM bitmap_demo.user_interest
  WHERE tenant_id = 20 AND snapshot_id = 1
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
-- @query q7.Bj answer=q7
SELECT o.predicate, o.inter AS intersection, o.size + s.n - o.inter AS union_size,
       ROUND(o.inter / (o.size + s.n - o.inter)::FLOAT, 4) AS jaccard
FROM (
  SELECT k.predicate,
         SUM(vbitmap.bm_cardinality(k.payload)) AS size,
         SUM(COALESCE(vbitmap.bm_and_cardinality(k.payload, a.payload), 0)) AS inter
  FROM bitmap_demo.bitmap_index k
  LEFT JOIN (SELECT chunk_id, payload FROM bitmap_demo.bitmap_index
             WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
               AND predicate = 'topic_sports') a ON a.chunk_id = k.chunk_id
  WHERE k.tenant_id = 20 AND k.snapshot_id = 1 AND k.domain = 'person'
    AND k.predicate LIKE 'topic\_%' AND k.predicate <> 'topic_sports'
  GROUP BY k.predicate
) o CROSS JOIN (
  SELECT SUM(vbitmap.bm_cardinality(payload)) AS n FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person' AND predicate = 'topic_sports'
) s;
-- @query q8.A answer=q8 oracle
SELECT p.entity_id
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 20 AND p.snapshot_id = 1 AND p.country = 'IL'
  AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
              WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                AND i.entity_id = p.entity_id AND i.topic = 'sports')
  AND NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                  WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                    AND i.entity_id = p.entity_id AND i.topic = 'finance');
-- @query q8.Bplus answer=q8
SELECT entity_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
) t;

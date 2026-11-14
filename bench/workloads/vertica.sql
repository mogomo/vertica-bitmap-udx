-- Vertica benchmark workload: the plan's queries on generated data, every path that answers them.
--   A   native SQL on the source tables (the oracle of each answer group)
--   At  the same, written so that Vertica plans it well (only where A is not already)
--   B   explicit bitmap SQL: joins of index rows on chunk_id with the scalar functions
--   B+  expression and facet transforms (bm_count, bm_ids, bm_facets): one scan per chunk
--   Bpar  facets and overlap on every thread of the query (bm_eval joined to the sets, bm_pair_count)
--   approx  APPROXIMATE_COUNT_DISTINCT (compared with the exact answer, never the same)
-- Data: scripts/generate.sh --default (events 2026-10-02 to 2026-10-31; asset refreshes 2026-09-01
-- to 2026-10-30). The bitmap forms read the tables (bench runs as an administrator), not the views.
-- Placeholders: tenant, src (source snapshot of the native forms), psnap / dsnap / asnap (person,
-- device and asset index snapshots), day1 / day3 (two days: day1 inclusive, day3 exclusive),
-- grid1 / grid8 (retention grid, 7 days), device_wm (device watermark), q5_cut (stale before).
-- index names the relation that holds the sets: the built index table (the default) or the live
-- projection bitmap_live.bitmap_index (scripts/live_index.sh). daily names the table of the daily
-- sets (bench/encoding_copy.sh makes copies of both with another payload encoding).
-- Run with bench/driver.py (format: its header).
-- @engine vertica
-- @set src=1
-- @set index=bitmap_demo.bitmap_index
-- @set daily=bitmap_demo.daily_bitmap
-- @set psnap=1
-- @set dsnap=1
-- @set asnap=1
-- @set day1=2026-10-15
-- @set day3=2026-10-17
-- @set grid1=2026-10-15
-- @set grid8=2026-10-22
-- @set device_wm=2026-11-01 12:00:00
-- @set q5_cut=2026-10-25
-- @set q5_expr=refreshed_2026_09_01 | refreshed_2026_09_02 | refreshed_2026_09_03 | refreshed_2026_09_04 | refreshed_2026_09_05 | refreshed_2026_09_06 | refreshed_2026_09_07 | refreshed_2026_09_08 | refreshed_2026_09_09 | refreshed_2026_09_10 | refreshed_2026_09_11 | refreshed_2026_09_12 | refreshed_2026_09_13 | refreshed_2026_09_14 | refreshed_2026_09_15 | refreshed_2026_09_16 | refreshed_2026_09_17 | refreshed_2026_09_18 | refreshed_2026_09_19 | refreshed_2026_09_20 | refreshed_2026_09_21 | refreshed_2026_09_22 | refreshed_2026_09_23 | refreshed_2026_09_24 | refreshed_2026_09_25 | refreshed_2026_09_26 | refreshed_2026_09_27 | refreshed_2026_09_28 | refreshed_2026_09_29 | refreshed_2026_09_30 | refreshed_2026_10_01 | refreshed_2026_10_02 | refreshed_2026_10_03 | refreshed_2026_10_04 | refreshed_2026_10_05 | refreshed_2026_10_06 | refreshed_2026_10_07 | refreshed_2026_10_08 | refreshed_2026_10_09 | refreshed_2026_10_10 | refreshed_2026_10_11 | refreshed_2026_10_12 | refreshed_2026_10_13 | refreshed_2026_10_14 | refreshed_2026_10_15 | refreshed_2026_10_16 | refreshed_2026_10_17 | refreshed_2026_10_18 | refreshed_2026_10_19 | refreshed_2026_10_20 | refreshed_2026_10_21 | refreshed_2026_10_22 | refreshed_2026_10_23 | refreshed_2026_10_24
-- @set q5_in='refreshed_2026_09_01', 'refreshed_2026_09_02', 'refreshed_2026_09_03', 'refreshed_2026_09_04', 'refreshed_2026_09_05', 'refreshed_2026_09_06', 'refreshed_2026_09_07', 'refreshed_2026_09_08', 'refreshed_2026_09_09', 'refreshed_2026_09_10', 'refreshed_2026_09_11', 'refreshed_2026_09_12', 'refreshed_2026_09_13', 'refreshed_2026_09_14', 'refreshed_2026_09_15', 'refreshed_2026_09_16', 'refreshed_2026_09_17', 'refreshed_2026_09_18', 'refreshed_2026_09_19', 'refreshed_2026_09_20', 'refreshed_2026_09_21', 'refreshed_2026_09_22', 'refreshed_2026_09_23', 'refreshed_2026_09_24', 'refreshed_2026_09_25', 'refreshed_2026_09_26', 'refreshed_2026_09_27', 'refreshed_2026_09_28', 'refreshed_2026_09_29', 'refreshed_2026_09_30', 'refreshed_2026_10_01', 'refreshed_2026_10_02', 'refreshed_2026_10_03', 'refreshed_2026_10_04', 'refreshed_2026_10_05', 'refreshed_2026_10_06', 'refreshed_2026_10_07', 'refreshed_2026_10_08', 'refreshed_2026_10_09', 'refreshed_2026_10_10', 'refreshed_2026_10_11', 'refreshed_2026_10_12', 'refreshed_2026_10_13', 'refreshed_2026_10_14', 'refreshed_2026_10_15', 'refreshed_2026_10_16', 'refreshed_2026_10_17', 'refreshed_2026_10_18', 'refreshed_2026_10_19', 'refreshed_2026_10_20', 'refreshed_2026_10_21', 'refreshed_2026_10_22', 'refreshed_2026_10_23', 'refreshed_2026_10_24'

-- ==== Q1 audience: IL, age 25 to 54, consent, not suspended, sports or finance ====

-- @query q1.count.A answer=q1.count oracle
SELECT COUNT(*) AS audience
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${src}
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
  AND p.consent IS TRUE AND p.suspended IS FALSE
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.user_interest i
    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
      AND i.entity_id = p.entity_id AND i.topic IN ('sports', 'finance'));

-- @query q1.count.B answer=q1.count
WITH k AS (
  SELECT predicate, chunk_id, payload FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
), cohort AS (
  SELECT a.chunk_id,
         vbitmap.bm_and(vbitmap.bm_and(a.payload, b.payload),
           vbitmap.bm_and(vbitmap.bm_and(c.payload, d.payload),
             vbitmap.bm_or(COALESCE(s.payload, vbitmap.bm_empty()),
                           COALESCE(f.payload, vbitmap.bm_empty())))) AS payload
  FROM k a
  JOIN k b ON b.chunk_id = a.chunk_id AND b.predicate = 'age_25_54'
  JOIN k c ON c.chunk_id = a.chunk_id AND c.predicate = 'consent_true'
  JOIN k d ON d.chunk_id = a.chunk_id AND d.predicate = 'suspended_false'
  LEFT JOIN k s ON s.chunk_id = a.chunk_id AND s.predicate = 'topic_sports'
  LEFT JOIN k f ON f.chunk_id = a.chunk_id AND f.predicate = 'topic_finance'
  WHERE a.predicate = 'country_IL'
)
SELECT COALESCE(SUM(vbitmap.bm_cardinality(payload)), 0) AS audience FROM cohort;

-- @query q1.count.Bplus answer=q1.count
SELECT COALESCE(SUM(cnt), 0) AS audience
FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')
) t;

-- @query q1.ids.A answer=q1.ids oracle
SELECT p.entity_id
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${src}
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
  AND p.consent IS TRUE AND p.suspended IS FALSE
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.user_interest i
    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
      AND i.entity_id = p.entity_id AND i.topic IN ('sports', 'finance'));

-- @query q1.ids.B answer=q1.ids
WITH k AS (
  SELECT predicate, chunk_id, payload FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
), cohort AS (
  SELECT a.chunk_id,
         vbitmap.bm_and(vbitmap.bm_and(a.payload, b.payload),
           vbitmap.bm_and(vbitmap.bm_and(c.payload, d.payload),
             vbitmap.bm_or(COALESCE(s.payload, vbitmap.bm_empty()),
                           COALESCE(f.payload, vbitmap.bm_empty())))) AS payload
  FROM k a
  JOIN k b ON b.chunk_id = a.chunk_id AND b.predicate = 'age_25_54'
  JOIN k c ON c.chunk_id = a.chunk_id AND c.predicate = 'consent_true'
  JOIN k d ON d.chunk_id = a.chunk_id AND d.predicate = 'suspended_false'
  LEFT JOIN k s ON s.chunk_id = a.chunk_id AND s.predicate = 'topic_sports'
  LEFT JOIN k f ON f.chunk_id = a.chunk_id AND f.predicate = 'topic_finance'
  WHERE a.predicate = 'country_IL'
)
SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS entity_id FROM cohort;

-- @query q1.ids.Bplus answer=q1.ids
SELECT entity_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')
) t;

-- ==== Q2 exact distinct web users over two days ====

-- @query q2.A answer=q2 oracle
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = ${tenant} AND channel = 'web'
  AND event_ts >= TIMESTAMP '${day1} 00:00:00' AND event_ts < TIMESTAMP '${day3} 00:00:00';

-- @query q2.B answer=q2
SELECT COALESCE(SUM(vbitmap.bm_cardinality(payload)), 0) AS users
FROM (
  SELECT vbitmap.bm_union(tenant_id, domain, chunk_id, payload)
         OVER (PARTITION BY tenant_id, domain, chunk_id)
  FROM ${daily}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND channel = 'web' AND day >= DATE '${day1}' AND day < DATE '${day3}'
) merged;

-- @query q2.approx answer=q2.approx approx=q2
SELECT APPROXIMATE_COUNT_DISTINCT(user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = ${tenant} AND channel = 'web'
  AND event_ts >= TIMESTAMP '${day1} 00:00:00' AND event_ts < TIMESTAMP '${day3} 00:00:00';

-- @query q2.daily.A answer=q2.daily oracle
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = ${tenant} AND channel = 'web'
  AND event_ts >= TIMESTAMP '${day1} 00:00:00' AND event_ts < TIMESTAMP '${day3} 00:00:00'
GROUP BY 1;

-- @query q2.daily.B answer=q2.daily
SELECT day, SUM(vbitmap.bm_cardinality(payload)) AS users
FROM ${daily}
WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
  AND channel = 'web' AND day >= DATE '${day1}' AND day < DATE '${day3}'
GROUP BY day;

-- ==== Q2b distinct users of web and app, same days, from the same stored sets ====

-- @query q2b.A answer=q2b oracle
SELECT COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = ${tenant} AND channel IN ('web', 'app')
  AND event_ts >= TIMESTAMP '${day1} 00:00:00' AND event_ts < TIMESTAMP '${day3} 00:00:00';

-- @query q2b.B answer=q2b
SELECT COALESCE(SUM(vbitmap.bm_cardinality(payload)), 0) AS users
FROM (
  SELECT vbitmap.bm_union(tenant_id, domain, chunk_id, payload)
         OVER (PARTITION BY tenant_id, domain, chunk_id)
  FROM ${daily}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND channel IN ('web', 'app') AND day >= DATE '${day1}' AND day < DATE '${day3}'
) merged;

-- ==== Q3 users per topic inside the Q1 audience ====

-- @query q3.A answer=q3 oracle
SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_demo.user_interest i
WHERE i.tenant_id = ${tenant} AND i.snapshot_id = ${src}
  AND i.entity_id IN (
    SELECT p.entity_id FROM bitmap_demo.user_profile p
    WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${src}
      AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
      AND p.consent IS TRUE AND p.suspended IS FALSE
      AND EXISTS (
        SELECT 1 FROM bitmap_demo.user_interest j
        WHERE j.tenant_id = p.tenant_id AND j.snapshot_id = p.snapshot_id
          AND j.entity_id = p.entity_id AND j.topic IN ('sports', 'finance')))
GROUP BY 1;

-- @query q3.B answer=q3
WITH k AS (
  SELECT predicate, chunk_id, payload FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
), cohort AS (
  SELECT a.chunk_id,
         vbitmap.bm_and(vbitmap.bm_and(a.payload, b.payload),
           vbitmap.bm_and(vbitmap.bm_and(c.payload, d.payload),
             vbitmap.bm_or(COALESCE(s.payload, vbitmap.bm_empty()),
                           COALESCE(f.payload, vbitmap.bm_empty())))) AS payload
  FROM k a
  JOIN k b ON b.chunk_id = a.chunk_id AND b.predicate = 'age_25_54'
  JOIN k c ON c.chunk_id = a.chunk_id AND c.predicate = 'consent_true'
  JOIN k d ON d.chunk_id = a.chunk_id AND d.predicate = 'suspended_false'
  LEFT JOIN k s ON s.chunk_id = a.chunk_id AND s.predicate = 'topic_sports'
  LEFT JOIN k f ON f.chunk_id = a.chunk_id AND f.predicate = 'topic_finance'
  WHERE a.predicate = 'country_IL'
)
SELECT t.predicate, SUM(vbitmap.bm_and_cardinality(c.payload, t.payload)) AS users
FROM cohort c
JOIN k t ON t.chunk_id = c.chunk_id AND t.predicate LIKE 'topic\_%'
GROUP BY t.predicate
HAVING SUM(vbitmap.bm_and_cardinality(c.payload, t.payload)) > 0;

-- @query q3.Bplus answer=q3
SELECT predicate, SUM(cnt) AS users
FROM (
  SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS
           expr = 'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)',
           facets = 'topic_')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND (predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false') OR predicate LIKE 'topic\_%')
) t
GROUP BY predicate;

-- Disjunctive facets: per topic, the audience without its topic filter.
-- @query q3d.A answer=q3d oracle
SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_demo.user_interest i
JOIN bitmap_demo.user_profile p
  ON p.tenant_id = i.tenant_id AND p.snapshot_id = i.snapshot_id AND p.entity_id = i.entity_id
WHERE i.tenant_id = ${tenant} AND i.snapshot_id = ${src}
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54 AND p.consent IS TRUE AND p.suspended IS FALSE
GROUP BY 1;

-- @query q3d.Bplus answer=q3d
SELECT predicate, SUM(cnt) AS users
FROM (
  SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS
           expr = 'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)',
           facets = 'topic_', exclude = 'topic_')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND (predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false') OR predicate LIKE 'topic\_%')
) t
GROUP BY predicate;

-- ==== Q4 devices: online, zone A, at least 80.0 C, more than 3 changes (IDs) ====

-- @query q4.A answer=q4 oracle
SELECT device_id
FROM bitmap_demo.device_state
WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
  AND observed_at > TIMESTAMPADD('minute', -30, '${device_wm}'::TIMESTAMP) AND observed_at <= '${device_wm}'::TIMESTAMP
  AND online IS TRUE AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;

-- @query q4.B answer=q4
WITH k AS (
  SELECT predicate, chunk_id, payload FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${dsnap} AND domain = 'device'
), hot AS (
  SELECT a.chunk_id,
         vbitmap.bm_and(vbitmap.bm_and(a.payload, b.payload), vbitmap.bm_and(c.payload, d.payload)) AS payload
  FROM k a
  JOIN k b ON b.chunk_id = a.chunk_id AND b.predicate = 'zone_A'
  JOIN k c ON c.chunk_id = a.chunk_id AND c.predicate = 'temp_ge_800'
  JOIN k d ON d.chunk_id = a.chunk_id AND d.predicate = 'changes_gt_3'
  WHERE a.predicate = 'online_true'
)
SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS device_id FROM hot;

-- @query q4.Bplus answer=q4
SELECT entity_id AS device_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'online_true & zone_A & temp_ge_800 & changes_gt_3')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${dsnap} AND domain = 'device'
    AND predicate IN ('online_true', 'zone_A', 'temp_ge_800', 'changes_gt_3')
) t;

-- ==== Q5 stale assets: PII, not deleted, from ERP_A, refreshed before q5_cut (IDs) ====

-- @query q5.A answer=q5 oracle
SELECT a.asset_id
FROM bitmap_demo.asset_state a
WHERE a.tenant_id = ${tenant} AND a.snapshot_id = ${src}
  AND a.contains_pii IS TRUE AND a.deleted IS FALSE
  AND a.refreshed_at < TIMESTAMP '${q5_cut} 00:00:00'
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.asset_source s
    WHERE s.tenant_id = a.tenant_id AND s.snapshot_id = a.snapshot_id
      AND s.asset_id = a.asset_id AND s.source = 'ERP_A');

-- @query q5.B answer=q5
WITH k AS (
  SELECT predicate, chunk_id, payload FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${asnap} AND domain = 'asset'
), refreshed AS (
  SELECT vbitmap.bm_union(chunk_id, payload) OVER (PARTITION BY chunk_id)
  FROM k WHERE predicate LIKE 'refreshed\_%' AND predicate < 'refreshed_' || REPLACE('${q5_cut}', '-', '_')
), stale AS (
  SELECT a.chunk_id,
         vbitmap.bm_and(vbitmap.bm_and(a.payload, b.payload), vbitmap.bm_and(c.payload, r.payload)) AS payload
  FROM k a
  JOIN k b ON b.chunk_id = a.chunk_id AND b.predicate = 'deleted_false'
  JOIN k c ON c.chunk_id = a.chunk_id AND c.predicate = 'source_ERP_A'
  JOIN refreshed r ON r.chunk_id = a.chunk_id
  WHERE a.predicate = 'pii_true'
)
SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS asset_id FROM stale;

-- The expression lists the refresh days before q5_cut (q5_expr, q5_in), as scripts/bmq would.
-- @query q5.Bplus answer=q5
SELECT entity_id AS asset_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'pii_true & deleted_false & source_ERP_A & (${q5_expr})')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${asnap} AND domain = 'asset'
    AND predicate IN ('pii_true', 'deleted_false', 'source_ERP_A', ${q5_in})
) t;

-- ==== Q6 retention grid: web users active on both days of every pair (7 days) ====

-- @query q6.A answer=q6 oracle
WITH d AS (
  SELECT DISTINCT event_ts::DATE AS day, user_id
  FROM bitmap_demo.event_log
  WHERE tenant_id = ${tenant} AND channel = 'web'
    AND event_ts >= TIMESTAMP '${grid1} 00:00:00' AND event_ts < TIMESTAMP '${grid8} 00:00:00'
)
SELECT a.day || ' ' || b.day AS days, COUNT(*) AS users
FROM d a JOIN d b ON b.user_id = a.user_id AND b.day >= a.day
GROUP BY a.day, b.day;

-- Tuned native form: the day set is written twice, inline, instead of a WITH clause read twice.
-- @query q6.At answer=q6
SELECT a.day || ' ' || b.day AS days, COUNT(*) AS users
FROM (SELECT DISTINCT event_ts::DATE AS day, user_id FROM bitmap_demo.event_log
      WHERE tenant_id = ${tenant} AND channel = 'web'
        AND event_ts >= TIMESTAMP '${grid1} 00:00:00' AND event_ts < TIMESTAMP '${grid8} 00:00:00') a
JOIN (SELECT DISTINCT event_ts::DATE AS day, user_id FROM bitmap_demo.event_log
      WHERE tenant_id = ${tenant} AND channel = 'web'
        AND event_ts >= TIMESTAMP '${grid1} 00:00:00' AND event_ts < TIMESTAMP '${grid8} 00:00:00') b
  ON b.user_id = a.user_id AND b.day >= a.day
GROUP BY a.day, b.day;

-- @query q6.B answer=q6
WITH s AS (
  SELECT day, chunk_id, payload FROM ${daily}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person' AND channel = 'web'
    AND day >= DATE '${grid1}' AND day < DATE '${grid8}'
)
SELECT a.day || ' ' || b.day AS days, SUM(vbitmap.bm_and_cardinality(a.payload, b.payload)) AS users
FROM s a JOIN s b ON b.chunk_id = a.chunk_id AND b.day >= a.day
GROUP BY a.day, b.day
HAVING SUM(vbitmap.bm_and_cardinality(a.payload, b.payload)) > 0;

-- ==== Q7 overlap ranking: Jaccard index of sports with every other topic ====

-- @query q7.A answer=q7 oracle
WITH t AS (
  SELECT DISTINCT topic, entity_id FROM bitmap_demo.user_interest
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
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

-- Tuned native form: no reused WITH clause (see q6.At).
-- @query q7.At answer=q7
SELECT 'topic_' || t.topic AS predicate, t.inter AS intersection, t.size + s.n - t.inter AS union_size,
       ROUND(t.inter / (t.size + s.n - t.inter)::FLOAT, 4) AS jaccard
FROM (
  SELECT u.topic, COUNT(*) AS size, SUM(CASE WHEN a.entity_id IS NULL THEN 0 ELSE 1 END) AS inter
  FROM (SELECT DISTINCT topic, entity_id FROM bitmap_demo.user_interest
        WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic <> 'sports') u
  LEFT JOIN (SELECT DISTINCT entity_id FROM bitmap_demo.user_interest
             WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'sports') a
    ON a.entity_id = u.entity_id
  GROUP BY u.topic
) t
CROSS JOIN (SELECT COUNT(DISTINCT entity_id) AS n FROM bitmap_demo.user_interest
            WHERE tenant_id = ${tenant} AND snapshot_id = ${src} AND topic = 'sports') s;

-- @query q7.B answer=q7
WITH k AS (
  SELECT predicate, chunk_id, payload FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate LIKE 'topic\_%'
), a AS (
  SELECT chunk_id, payload FROM k WHERE predicate = 'topic_sports'
), o AS (
  SELECT k.predicate,
         SUM(vbitmap.bm_cardinality(k.payload)) AS size,
         SUM(COALESCE(vbitmap.bm_and_cardinality(k.payload, a.payload), 0)) AS inter
  FROM k LEFT JOIN a ON a.chunk_id = k.chunk_id
  WHERE k.predicate <> 'topic_sports'
  GROUP BY k.predicate
)
SELECT predicate, inter AS intersection, size + (SELECT SUM(vbitmap.bm_cardinality(payload)) FROM a) - inter AS union_size,
       ROUND(inter / (size + (SELECT SUM(vbitmap.bm_cardinality(payload)) FROM a) - inter)::FLOAT, 4) AS jaccard
FROM o;

-- The same computation with plain subqueries instead of a WITH clause that is read three times:
-- the form used for the 100 M measurements.
-- @query q7.Bj answer=q7
SELECT o.predicate, o.inter AS intersection, o.size + s.n - o.inter AS union_size,
       ROUND(o.inter / (o.size + s.n - o.inter)::FLOAT, 4) AS jaccard
FROM (
  SELECT k.predicate,
         SUM(vbitmap.bm_cardinality(k.payload)) AS size,
         SUM(COALESCE(vbitmap.bm_and_cardinality(k.payload, a.payload), 0)) AS inter
  FROM ${index} k
  LEFT JOIN (SELECT chunk_id, payload FROM ${index}
             WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
               AND predicate = 'topic_sports') a ON a.chunk_id = k.chunk_id
  WHERE k.tenant_id = ${tenant} AND k.snapshot_id = ${psnap} AND k.domain = 'person'
    AND k.predicate LIKE 'topic\_%' AND k.predicate <> 'topic_sports'
  GROUP BY k.predicate
) o CROSS JOIN (
  SELECT SUM(vbitmap.bm_cardinality(payload)) AS n FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person' AND predicate = 'topic_sports'
) s;

-- Facet form: one bm_facets pass gives |sports AND t| for every topic t; the size of every topic set
-- is in the snapshot's predicate list (bitmap_predicate.cardinality, checked by the validation).
-- @query q7.Bplus answer=q7
WITH f AS (
  SELECT predicate, SUM(cnt) AS inter
  FROM (
    SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_sports', facets = 'topic_')
           OVER (PARTITION BY chunk_id)
    FROM ${index}
    WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person' AND predicate LIKE 'topic\_%'
  ) t
  GROUP BY predicate
), s AS (
  SELECT cardinality AS n FROM bitmap_demo.bitmap_predicate
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person' AND predicate = 'topic_sports'
)
SELECT p.predicate, COALESCE(f.inter, 0) AS intersection, p.cardinality + s.n - COALESCE(f.inter, 0) AS union_size,
       ROUND(COALESCE(f.inter, 0) / (p.cardinality + s.n - COALESCE(f.inter, 0))::FLOAT, 4) AS jaccard
FROM bitmap_demo.bitmap_predicate p CROSS JOIN s LEFT JOIN f ON f.predicate = p.predicate
WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${psnap} AND p.domain = 'person'
  AND p.predicate LIKE 'topic\_%' AND p.predicate <> 'topic_sports';

-- The same two questions for one user on every thread of the query (Bpar): the audience of each
-- chunk (bm_eval) is joined to the facet rows and bm_pair_count counts each pair; its rows are
-- independent, so OVER (PARTITION BEST) lets Vertica spread them over the query's threads. More
-- CPU in total than the one-pass forms above, less waiting when the machine is not shared.

-- @query q3.Bpar answer=q3
SELECT name AS predicate, SUM(cnt) AS users
FROM (
  SELECT vbitmap.bm_pair_count(f.predicate, a.payload, f.payload) OVER (PARTITION BEST)
  FROM ${index} f
  JOIN (SELECT chunk_id, payload FROM (
          SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr =
                   'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
                 OVER (PARTITION BY chunk_id)
          FROM ${index}
          WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
            AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')) e) a
    ON a.chunk_id = f.chunk_id
  WHERE f.tenant_id = ${tenant} AND f.snapshot_id = ${psnap} AND f.domain = 'person' AND f.predicate LIKE 'topic\_%'
) t
GROUP BY name;

-- @query q7.Bpar answer=q7
WITH f AS (
  SELECT name AS predicate, SUM(cnt) AS inter
  FROM (
    SELECT vbitmap.bm_pair_count(k.predicate, a.payload, k.payload) OVER (PARTITION BEST)
    FROM ${index} k
    JOIN (SELECT chunk_id, payload FROM ${index}
          WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person' AND predicate = 'topic_sports') a
      ON a.chunk_id = k.chunk_id
    WHERE k.tenant_id = ${tenant} AND k.snapshot_id = ${psnap} AND k.domain = 'person' AND k.predicate LIKE 'topic\_%'
  ) t
  GROUP BY name
), s AS (
  SELECT cardinality AS n FROM bitmap_demo.bitmap_predicate
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person' AND predicate = 'topic_sports'
)
SELECT p.predicate, COALESCE(f.inter, 0) AS intersection, p.cardinality + s.n - COALESCE(f.inter, 0) AS union_size,
       ROUND(COALESCE(f.inter, 0) / (p.cardinality + s.n - COALESCE(f.inter, 0))::FLOAT, 4) AS jaccard
FROM bitmap_demo.bitmap_predicate p CROSS JOIN s LEFT JOIN f ON f.predicate = p.predicate
WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${psnap} AND p.domain = 'person'
  AND p.predicate LIKE 'topic\_%' AND p.predicate <> 'topic_sports';

-- ==== Q8 IL users interested in sports and not in finance (IDs) ====

-- @query q8.A answer=q8 oracle
SELECT p.entity_id
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${src} AND p.country = 'IL'
  AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
              WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                AND i.entity_id = p.entity_id AND i.topic = 'sports')
  AND NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                  WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                    AND i.entity_id = p.entity_id AND i.topic = 'finance');

-- @query q8.B answer=q8
WITH k AS (
  SELECT predicate, chunk_id, payload FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
), x AS (
  SELECT a.chunk_id,
         vbitmap.bm_andnot(vbitmap.bm_and(a.payload, s.payload), COALESCE(f.payload, vbitmap.bm_empty())) AS payload
  FROM k a
  JOIN k s ON s.chunk_id = a.chunk_id AND s.predicate = 'topic_sports'
  LEFT JOIN k f ON f.chunk_id = a.chunk_id AND f.predicate = 'topic_finance'
  WHERE a.predicate = 'country_IL'
)
SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS entity_id FROM x;

-- @query q8.Bplus answer=q8
SELECT entity_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
) t;

-- NULL trap: "not suspended" as a complement against the explicit set.
-- @query q8trap.A answer=q8trap oracle
SELECT SUM(CASE WHEN suspended IS TRUE THEN 0 ELSE 1 END) AS complement,
       SUM(CASE WHEN suspended IS FALSE THEN 1 ELSE 0 END) AS explicit
FROM bitmap_demo.user_profile
WHERE tenant_id = ${tenant} AND snapshot_id = ${src};

-- @query q8trap.Bplus answer=q8trap
SELECT (SELECT COALESCE(SUM(cnt), 0) FROM (
          SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'all - suspended_true')
                 OVER (PARTITION BY chunk_id)
          FROM ${index}
          WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
            AND predicate IN ('all', 'suspended_true')) a) AS complement,
       (SELECT COALESCE(SUM(cnt), 0) FROM (
          SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'suspended_false')
                 OVER (PARTITION BY chunk_id)
          FROM ${index}
          WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
            AND predicate IN ('suspended_false')) b) AS explicit;

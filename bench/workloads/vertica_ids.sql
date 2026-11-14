-- Vertica workload of the ID-list tests (chain 14): what an ID list costs and what it is used for.
-- Same data, sets and answers as bench/workloads/vertica.sql (Q1 audience, Q4 devices, Q8 audience).
--   ids    one row per ID (the form of vertica.sql), native (A) and bm_ids (B+)
--   rowtext  one row per ID with the ID formatted by the function (bm_ids ... text = true): the
--          same bytes on the wire as the INT column, for a list that goes to a client
--   text   bm_ids_text: the same list as text blocks, one ID per line; the driver counts a line as a
--          row, so the answer is compared with the same oracle
--   sum    the list consumed inside the engine: COUNT(*) and SUM of the IDs
--   join   the list joined to the profile table: people, people with a known age, sum of ages.
--          Bplus: the ID list as the inner side of a semi-join. Bpin: the audience pinned in
--          memory (bm_pin) and every profile row tested against it on the scan threads
--          (bm_member); two statements sent as one message. The row bm_pin returns (members,
--          chunks) is filtered away so that the answer is the one row of totals, as in the
--          other forms; the NULL row makes an empty audience an empty set.
--   agg    the same three numbers from set counts alone, no join: the age stored as bit-sliced
--          sets (sql/families_bitsliced.sql; bench/bitsliced.sh add puts them into the snapshot)
--   save   the audience kept in the database: as a set (bm_eval rows) or as a table of IDs. Target
--          tables: bench/vertica_idtests.sql. Each execution adds the audience again; the row count
--          the INSERT reports is the answer.
-- index names the relation that holds the sets (default: the built index table; the live
-- projection: bitmap_live.bitmap_index). Run with bench/driver.py; --client=socket reads the
-- results as raw bytes, as the driver reads ClickHouse.
-- @engine vertica
-- @set src=1
-- @set psnap=1
-- @set dsnap=1
-- @set index=bitmap_demo.bitmap_index
-- @set device_wm=2026-11-01 12:00:00

-- ==== one row per ID ====

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

-- @query q4.A answer=q4 oracle
SELECT device_id AS entity_id
  FROM bitmap_demo.device_state
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
    AND observed_at > TIMESTAMPADD('minute', -30, '${device_wm}'::TIMESTAMP) AND observed_at <= '${device_wm}'::TIMESTAMP
    AND online IS TRUE AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;

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

-- ==== one row per ID, formatted by the function ====

-- @query q1.ids.rowtext.Bplus answer=q1.ids
SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)', text = true)
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance');

-- @query q4.rowtext.Bplus answer=q4
SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'online_true & zone_A & temp_ge_800 & changes_gt_3', text = true)
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${dsnap} AND domain = 'device'
    AND predicate IN ('online_true', 'zone_A', 'temp_ge_800', 'changes_gt_3');

-- @query q8.rowtext.Bplus answer=q8
SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance', text = true)
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance');

-- ==== the same lists as text blocks ====

-- @query q1.ids.text.Bplus answer=q1.ids
SELECT vbitmap.bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance');

-- @query q4.text.Bplus answer=q4
SELECT vbitmap.bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr =
           'online_true & zone_A & temp_ge_800 & changes_gt_3')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${dsnap} AND domain = 'device'
    AND predicate IN ('online_true', 'zone_A', 'temp_ge_800', 'changes_gt_3');

-- @query q8.text.Bplus answer=q8
SELECT vbitmap.bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance');

-- ==== the list consumed inside the engine ====

-- @query q1.ids.sum.A answer=q1.ids.sum oracle
SELECT COUNT(*) AS ids, SUM(entity_id) AS id_sum FROM (
  SELECT p.entity_id
  FROM bitmap_demo.user_profile p
  WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${src}
    AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
    AND p.consent IS TRUE AND p.suspended IS FALSE
    AND EXISTS (
      SELECT 1 FROM bitmap_demo.user_interest i
      WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
        AND i.entity_id = p.entity_id AND i.topic IN ('sports', 'finance'))
) t;

-- @query q1.ids.sum.Bplus answer=q1.ids.sum
SELECT COUNT(*) AS ids, SUM(entity_id) AS id_sum FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')
) t;

-- @query q4.sum.A answer=q4.sum oracle
SELECT COUNT(*) AS ids, SUM(entity_id) AS id_sum FROM (
  SELECT device_id AS entity_id
  FROM bitmap_demo.device_state
  WHERE tenant_id = ${tenant} AND snapshot_id = ${src}
    AND observed_at > TIMESTAMPADD('minute', -30, '${device_wm}'::TIMESTAMP) AND observed_at <= '${device_wm}'::TIMESTAMP
    AND online IS TRUE AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3
) t;

-- @query q4.sum.Bplus answer=q4.sum
SELECT COUNT(*) AS ids, SUM(entity_id) AS id_sum FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'online_true & zone_A & temp_ge_800 & changes_gt_3')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${dsnap} AND domain = 'device'
    AND predicate IN ('online_true', 'zone_A', 'temp_ge_800', 'changes_gt_3')
) t;

-- @query q8.sum.A answer=q8.sum oracle
SELECT COUNT(*) AS ids, SUM(entity_id) AS id_sum FROM (
  SELECT p.entity_id
  FROM bitmap_demo.user_profile p
  WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${src} AND p.country = 'IL'
    AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                  AND i.entity_id = p.entity_id AND i.topic = 'sports')
    AND NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                      AND i.entity_id = p.entity_id AND i.topic = 'finance')
) t;

-- @query q8.sum.Bplus answer=q8.sum
SELECT COUNT(*) AS ids, SUM(entity_id) AS id_sum FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
) t;

-- ==== the list joined to the profile table ====

-- @query q8.join.A answer=q8.join oracle
SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = ${tenant} AND x.snapshot_id = ${src} AND x.entity_id IN (
  SELECT p.entity_id
  FROM bitmap_demo.user_profile p
  WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${src} AND p.country = 'IL'
    AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                  AND i.entity_id = p.entity_id AND i.topic = 'sports')
    AND NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                      AND i.entity_id = p.entity_id AND i.topic = 'finance'));

-- @query q8.join.Bplus answer=q8.join
SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = ${tenant} AND x.snapshot_id = ${src} AND x.entity_id IN (
  SELECT entity_id FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
  ) t);

-- @query q8.join.Bpin answer=q8.join
SELECT members FROM (
  SELECT vbitmap.bm_pin(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance', name = 'q8')
         OVER ()
  FROM (SELECT chunk_id, predicate, payload FROM ${index}
        WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
          AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
        UNION ALL SELECT NULL, NULL, NULL) r
) p WHERE members < 0;
SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = ${tenant} AND x.snapshot_id = ${src}
  AND vbitmap.bm_member(x.entity_id USING PARAMETERS name = 'q8');

-- ==== the same totals without a join: bit-sliced sets ====

-- @query q8.agg.Bplus answer=q8.join
SELECT people, age_known, CASE WHEN age_known > 0 THEN bit_sum END AS age_sum
FROM (
  SELECT COALESCE(SUM(CASE WHEN predicate = 'all' THEN cnt END), 0) AS people,
         COALESCE(SUM(CASE WHEN predicate = 'age_known' THEN cnt END), 0) AS age_known,
         COALESCE(SUM(CASE WHEN predicate LIKE 'age\_bit\_%'
                           THEN cnt * (1 << SPLIT_PART(predicate, '_', 3)::INT) END), 0) AS bit_sum
  FROM (
    SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS
             expr = 'country_IL & topic_sports - topic_finance', facets = '')
           OVER (PARTITION BY chunk_id)
    FROM ${index}
    WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
      AND (predicate IN ('country_IL', 'topic_sports', 'topic_finance', 'all', 'age_known')
           OR predicate LIKE 'age\_bit\_%')
  ) f
) t;

-- ==== the audience kept in the database ====

-- @query q8.save.set.Bplus answer=q8.save.set
INSERT INTO bitmap_bench.saved_set (audience, chunk_id, payload)
SELECT 'q8', chunk_id, payload FROM (
  SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
) t; COMMIT;

-- @query q8.save.ids.A answer=q8.save.ids
INSERT INTO bitmap_bench.saved_ids (audience, entity_id)
SELECT 'q8', entity_id FROM (
  SELECT p.entity_id
  FROM bitmap_demo.user_profile p
  WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${src} AND p.country = 'IL'
    AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                  AND i.entity_id = p.entity_id AND i.topic = 'sports')
    AND NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                      AND i.entity_id = p.entity_id AND i.topic = 'finance')
) t; COMMIT;

-- @query q8.save.ids.Bplus answer=q8.save.ids
INSERT INTO bitmap_bench.saved_ids (audience, entity_id)
SELECT 'q8', entity_id FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM ${index}
  WHERE tenant_id = ${tenant} AND snapshot_id = ${psnap} AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
) t; COMMIT;

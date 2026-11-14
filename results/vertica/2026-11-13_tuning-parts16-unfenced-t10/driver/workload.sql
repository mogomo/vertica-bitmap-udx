-- @engine vertica
-- @set asnap=1
-- @set day1=2026-10-15
-- @set day3=2026-10-17
-- @set device_wm=2026-11-01 12:00:00
-- @set dsnap=1
-- @set grid1=2026-10-15
-- @set grid8=2026-10-22
-- @set index=bitmap_bench.bitmap_index_parts
-- @set psnap=1
-- @set q5_cut=2026-10-25
-- @set q5_expr=refreshed_2026_09_01 | refreshed_2026_09_02 | refreshed_2026_09_03 | refreshed_2026_09_04 | refreshed_2026_09_05 | refreshed_2026_09_06 | refreshed_2026_09_07 | refreshed_2026_09_08 | refreshed_2026_09_09 | refreshed_2026_09_10 | refreshed_2026_09_11 | refreshed_2026_09_12 | refreshed_2026_09_13 | refreshed_2026_09_14 | refreshed_2026_09_15 | refreshed_2026_09_16 | refreshed_2026_09_17 | refreshed_2026_09_18 | refreshed_2026_09_19 | refreshed_2026_09_20 | refreshed_2026_09_21 | refreshed_2026_09_22 | refreshed_2026_09_23 | refreshed_2026_09_24 | refreshed_2026_09_25 | refreshed_2026_09_26 | refreshed_2026_09_27 | refreshed_2026_09_28 | refreshed_2026_09_29 | refreshed_2026_09_30 | refreshed_2026_10_01 | refreshed_2026_10_02 | refreshed_2026_10_03 | refreshed_2026_10_04 | refreshed_2026_10_05 | refreshed_2026_10_06 | refreshed_2026_10_07 | refreshed_2026_10_08 | refreshed_2026_10_09 | refreshed_2026_10_10 | refreshed_2026_10_11 | refreshed_2026_10_12 | refreshed_2026_10_13 | refreshed_2026_10_14 | refreshed_2026_10_15 | refreshed_2026_10_16 | refreshed_2026_10_17 | refreshed_2026_10_18 | refreshed_2026_10_19 | refreshed_2026_10_20 | refreshed_2026_10_21 | refreshed_2026_10_22 | refreshed_2026_10_23 | refreshed_2026_10_24
-- @set q5_in='refreshed_2026_09_01', 'refreshed_2026_09_02', 'refreshed_2026_09_03', 'refreshed_2026_09_04', 'refreshed_2026_09_05', 'refreshed_2026_09_06', 'refreshed_2026_09_07', 'refreshed_2026_09_08', 'refreshed_2026_09_09', 'refreshed_2026_09_10', 'refreshed_2026_09_11', 'refreshed_2026_09_12', 'refreshed_2026_09_13', 'refreshed_2026_09_14', 'refreshed_2026_09_15', 'refreshed_2026_09_16', 'refreshed_2026_09_17', 'refreshed_2026_09_18', 'refreshed_2026_09_19', 'refreshed_2026_09_20', 'refreshed_2026_09_21', 'refreshed_2026_09_22', 'refreshed_2026_09_23', 'refreshed_2026_09_24', 'refreshed_2026_09_25', 'refreshed_2026_09_26', 'refreshed_2026_09_27', 'refreshed_2026_09_28', 'refreshed_2026_09_29', 'refreshed_2026_09_30', 'refreshed_2026_10_01', 'refreshed_2026_10_02', 'refreshed_2026_10_03', 'refreshed_2026_10_04', 'refreshed_2026_10_05', 'refreshed_2026_10_06', 'refreshed_2026_10_07', 'refreshed_2026_10_08', 'refreshed_2026_10_09', 'refreshed_2026_10_10', 'refreshed_2026_10_11', 'refreshed_2026_10_12', 'refreshed_2026_10_13', 'refreshed_2026_10_14', 'refreshed_2026_10_15', 'refreshed_2026_10_16', 'refreshed_2026_10_17', 'refreshed_2026_10_18', 'refreshed_2026_10_19', 'refreshed_2026_10_20', 'refreshed_2026_10_21', 'refreshed_2026_10_22', 'refreshed_2026_10_23', 'refreshed_2026_10_24'
-- @set src=1
-- @set tenant=10
-- @query q1.count.Bplus answer=q1.count
SELECT COALESCE(SUM(cnt), 0) AS audience
FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_bench.bitmap_index_parts
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')
) t;
-- @query q3.Bplus answer=q3
SELECT predicate, SUM(cnt) AS users
FROM (
  SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS
           expr = 'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)',
           facets = 'topic_')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_bench.bitmap_index_parts
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
    AND (predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false') OR predicate LIKE 'topic\_%')
) t
GROUP BY predicate;
-- @query q3.Bpar answer=q3
SELECT name AS predicate, SUM(cnt) AS users
FROM (
  SELECT vbitmap.bm_pair_count(f.predicate, a.payload, f.payload) OVER (PARTITION BEST)
  FROM bitmap_bench.bitmap_index_parts f
  JOIN (SELECT chunk_id, payload FROM (
          SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr =
                   'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
                 OVER (PARTITION BY chunk_id)
          FROM bitmap_bench.bitmap_index_parts
          WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
            AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance')) e) a
    ON a.chunk_id = f.chunk_id
  WHERE f.tenant_id = 10 AND f.snapshot_id = 1 AND f.domain = 'person' AND f.predicate LIKE 'topic\_%'
) t
GROUP BY name;

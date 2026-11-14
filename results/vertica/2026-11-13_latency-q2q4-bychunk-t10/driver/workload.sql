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
-- @query q2.daily.A answer=q2.daily oracle
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 10 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00'
GROUP BY 1;
-- @query q2.daily.B answer=q2.daily
SELECT day, SUM(vbitmap.bm_cardinality(payload)) AS users
FROM bitmap_demo.daily_bitmap
WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
  AND channel = 'web' AND day >= DATE '2026-10-15' AND day < DATE '2026-10-17'
GROUP BY day;
-- @query q4.A answer=q4 oracle
SELECT device_id
FROM bitmap_demo.device_state
WHERE tenant_id = 10 AND snapshot_id = 1
  AND observed_at > TIMESTAMPADD('minute', -30, '2026-11-01 12:00:00'::TIMESTAMP) AND observed_at <= '2026-11-01 12:00:00'::TIMESTAMP
  AND online IS TRUE AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;
-- @query q4.Bplus answer=q4
SELECT entity_id AS device_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'online_true & zone_A & temp_ge_800 & changes_gt_3')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'device'
    AND predicate IN ('online_true', 'zone_A', 'temp_ge_800', 'changes_gt_3')
) t;

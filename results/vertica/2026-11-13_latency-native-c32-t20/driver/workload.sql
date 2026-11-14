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
-- @query q2.daily.A answer=q2.daily oracle
SELECT event_ts::DATE AS day, COUNT(DISTINCT user_id) AS users
FROM bitmap_demo.event_log
WHERE tenant_id = 20 AND channel = 'web'
  AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-17 00:00:00'
GROUP BY 1;
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

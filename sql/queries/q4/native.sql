-- Q4 devices, native SQL: online, zone A, at least 80.0 C, more than 3 changes in 10 minutes,
-- at watermark ${watermark}: only observations at most 30 minutes old count (sql/families.sql).
SELECT device_id
FROM bitmap_demo.device_state
WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot}
  AND observed_at > TIMESTAMPADD('minute', -30, ${watermark}) AND observed_at <= ${watermark}
  AND online IS TRUE AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;

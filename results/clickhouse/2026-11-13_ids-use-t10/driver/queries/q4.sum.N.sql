SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
  SELECT device_id AS entity_id
  FROM xbench.device_state
  WHERE tenant_id = 10 AND snapshot_id = 1
    AND observed_at > toDateTime('2026-11-01 12:00:00', 'UTC') - INTERVAL 30 MINUTE AND observed_at <= toDateTime('2026-11-01 12:00:00', 'UTC')
    AND online = true AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3);

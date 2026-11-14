-- @engine clickhouse
-- @set bsnap=1
-- @set device_wm=2026-11-01 12:00:00
-- @set ptable=xbench.person_bitmap
-- @set src=1
-- @set tenant=10
-- @query q1.ids.N answer=q1.ids oracle
SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = 10 AND snapshot_id = 1
    AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = 10 AND snapshot_id = 1 AND topic IN ('sports', 'finance'));
-- @query q4.N answer=q4 oracle
SELECT device_id AS entity_id
  FROM xbench.device_state
  WHERE tenant_id = 10 AND snapshot_id = 1
    AND observed_at > toDateTime('2026-11-01 12:00:00', 'UTC') - INTERVAL 30 MINUTE AND observed_at <= toDateTime('2026-11-01 12:00:00', 'UTC')
    AND online = true AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3;
-- @query q8.N answer=q8 oracle
SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = 10 AND snapshot_id = 1 AND country = 'IL'
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports')
    AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                          WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'finance');

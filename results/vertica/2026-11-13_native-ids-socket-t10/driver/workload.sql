-- @engine vertica
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

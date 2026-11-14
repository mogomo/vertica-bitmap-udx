SELECT p.entity_id
FROM bitmap_dbd.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1 AND p.country = 'IL'
  AND EXISTS (SELECT 1 FROM bitmap_dbd.user_interest i
              WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                AND i.entity_id = p.entity_id AND i.topic = 'sports')
  AND NOT EXISTS (SELECT 1 FROM bitmap_dbd.user_interest i
                  WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                    AND i.entity_id = p.entity_id AND i.topic = 'finance');

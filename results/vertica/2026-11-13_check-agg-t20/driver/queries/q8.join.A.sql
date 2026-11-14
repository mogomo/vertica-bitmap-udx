SELECT COUNT(*) AS people, COUNT(x.age) AS age_known, SUM(x.age) AS age_sum
FROM bitmap_demo.user_profile x
WHERE x.tenant_id = 20 AND x.snapshot_id = 1 AND x.entity_id IN (
  SELECT p.entity_id
  FROM bitmap_demo.user_profile p
  WHERE p.tenant_id = 20 AND p.snapshot_id = 1 AND p.country = 'IL'
    AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                  AND i.entity_id = p.entity_id AND i.topic = 'sports')
    AND NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                    WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                      AND i.entity_id = p.entity_id AND i.topic = 'finance'));

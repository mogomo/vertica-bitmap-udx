-- Q9 attribute totals over an audience, native SQL: people, people with a known age and the sum
-- of their ages in the Q8 audience (IL, sports, not finance). Average age = age_sum / age_known.
SELECT COUNT(*) AS people, COUNT(p.age) AS age_known, SUM(p.age) AS age_sum
FROM bitmap_demo.user_profile p
WHERE p.tenant_id = ${tenant} AND p.snapshot_id = ${snapshot} AND p.country = 'IL'
  AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
              WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                AND i.entity_id = p.entity_id AND i.topic = 'sports')
  AND NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                  WHERE i.tenant_id = p.tenant_id AND i.snapshot_id = p.snapshot_id
                    AND i.entity_id = p.entity_id AND i.topic = 'finance');

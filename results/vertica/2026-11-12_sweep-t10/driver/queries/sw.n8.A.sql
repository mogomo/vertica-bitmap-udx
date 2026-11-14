SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND ((p.country = 'IL' AND p.consent IS TRUE) AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic IN ('t10', 't11', 't12', 't13', 't14', 't15')));

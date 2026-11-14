SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_demo.user_interest i
WHERE i.tenant_id = 20 AND i.snapshot_id = 1
  AND i.entity_id IN (
    SELECT p.entity_id FROM bitmap_demo.user_profile p
    WHERE p.tenant_id = 20 AND p.snapshot_id = 1
      AND p.country = 'IL' AND p.age BETWEEN 25 AND 54
      AND p.consent IS TRUE AND p.suspended IS FALSE
      AND EXISTS (
        SELECT 1 FROM bitmap_demo.user_interest j
        WHERE j.tenant_id = p.tenant_id AND j.snapshot_id = p.snapshot_id
          AND j.entity_id = p.entity_id AND j.topic IN ('sports', 'finance')))
GROUP BY 1;

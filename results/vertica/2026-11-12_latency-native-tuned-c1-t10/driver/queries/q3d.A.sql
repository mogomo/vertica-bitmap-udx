SELECT 'topic_' || i.topic AS predicate, COUNT(DISTINCT i.entity_id) AS users
FROM bitmap_demo.user_interest i
JOIN bitmap_demo.user_profile p
  ON p.tenant_id = i.tenant_id AND p.snapshot_id = i.snapshot_id AND p.entity_id = i.entity_id
WHERE i.tenant_id = 10 AND i.snapshot_id = 1
  AND p.country = 'IL' AND p.age BETWEEN 25 AND 54 AND p.consent IS TRUE AND p.suspended IS FALSE
GROUP BY 1;

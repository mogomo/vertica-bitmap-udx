SELECT entity_id
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1
  AND country = 'IL' AND age BETWEEN 25 AND 54 AND consent = true AND suspended = false
  AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                    WHERE tenant_id = 10 AND snapshot_id = 1 AND topic IN ('sports', 'finance'));

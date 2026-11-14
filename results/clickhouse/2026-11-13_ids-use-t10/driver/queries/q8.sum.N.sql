SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
  SELECT entity_id
  FROM xbench.user_profile
  WHERE tenant_id = 10 AND snapshot_id = 1 AND country = 'IL'
    AND entity_id IN (SELECT entity_id FROM xbench.user_interest
                      WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'sports')
    AND entity_id NOT IN (SELECT entity_id FROM xbench.user_interest
                          WHERE tenant_id = 10 AND snapshot_id = 1 AND topic = 'finance'));

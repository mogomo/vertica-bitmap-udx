SELECT COALESCE(SUM(vbitmap.bm_cardinality(payload)), 0) AS users
FROM (
  SELECT vbitmap.bm_union(tenant_id, domain, chunk_id, payload)
         OVER (PARTITION BY tenant_id, domain, chunk_id)
  FROM bitmap_demo.daily_bitmap
  WHERE tenant_id = 12 AND snapshot_id = 1 AND domain = 'person'
    AND channel = 'web' AND day >= DATE '2026-10-15' AND day < DATE '2026-10-17'
) merged;

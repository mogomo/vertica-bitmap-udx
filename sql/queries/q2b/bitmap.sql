-- Q2b additive roll-up: the same stored (day, channel) sets, any combination; the sets are united inside each
-- chunk first, then the chunk cardinalities are summed (chunks are disjoint).
SELECT COALESCE(SUM(vbitmap.bm_cardinality(payload)), 0) AS users
FROM (
  SELECT vbitmap.bm_union(tenant_id, domain, chunk_id, payload)
         OVER (PARTITION BY tenant_id, domain, chunk_id)
  FROM bitmap_demo.daily_bitmap
  WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person'
    AND channel IN ('web', 'app') AND day >= DATE '2026-11-01' AND day < DATE '2026-11-03'
) merged;

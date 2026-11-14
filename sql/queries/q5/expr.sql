-- Q5 stale assets, expression transform. The refresh buckets before the cutoff are listed in
-- the expression: scripts/bmq builds the list from bitmap_demo.bitmap_predicate.
SELECT entity_id AS asset_id
FROM (
  SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'pii_true & deleted_false & source_ERP_A & (refreshed_2026_10_20)')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'asset'
    AND predicate IN ('pii_true', 'deleted_false', 'source_ERP_A', 'refreshed_2026_10_20')
) t;

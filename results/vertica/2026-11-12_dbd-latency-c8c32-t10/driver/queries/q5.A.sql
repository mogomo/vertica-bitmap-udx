SELECT a.asset_id
FROM bitmap_demo.asset_state a
WHERE a.tenant_id = 10 AND a.snapshot_id = 1
  AND a.contains_pii IS TRUE AND a.deleted IS FALSE
  AND a.refreshed_at < TIMESTAMP '2026-10-25 00:00:00'
  AND EXISTS (
    SELECT 1 FROM bitmap_demo.asset_source s
    WHERE s.tenant_id = a.tenant_id AND s.snapshot_id = a.snapshot_id
      AND s.asset_id = a.asset_id AND s.source = 'ERP_A');

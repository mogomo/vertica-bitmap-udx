-- A second projection of the bitmap index, sorted by chunk inside (tenant, snapshot, domain).
-- The expression and facet transforms partition by chunk_id; on bitmap_index_super (sorted by
-- predicate, then chunk) Vertica sorts every input row by chunk first (plan: "Group Sort:
-- chunk_id"), about 400 MB per facet query at 10 M people. Sorted by chunk, the rows arrive grouped.
-- Experiment of 2026-11-12 (ClickHouse comparison); bench/vertica_projection_bychunk_drop.sql removes it.
CREATE PROJECTION bitmap_demo.bitmap_index_by_chunk
    (tenant_id, snapshot_id, domain, predicate, chunk_id, payload ENCODING ZSTD_FAST_COMP) AS
SELECT tenant_id, snapshot_id, domain, predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
ORDER BY tenant_id, snapshot_id, domain, chunk_id, predicate
SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES;
SELECT REFRESH('bitmap_demo.bitmap_index');
SELECT 'summary: projection=bitmap_index_by_chunk up_to_date=' || is_up_to_date FROM v_catalog.projections
WHERE projection_schema = 'bitmap_demo' AND projection_name = 'bitmap_index_by_chunk';

-- A copy of one tenant's person index stored in several ROS containers (table partitions of chunk
-- ranges), for the tuning experiment of chain 17. Vertica reads the containers of a table on
-- separate threads, so the multi-threaded facet form (q3.Bpar) also reads the sets on every thread;
-- the one-pass forms need the chunks in order and merge the containers instead.
-- vsql variables: tenant, snapshot, per_partition (chunks per partition).
DROP TABLE IF EXISTS bitmap_bench.bitmap_index_parts CASCADE;
CREATE TABLE bitmap_bench.bitmap_index_parts (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL,
    domain VARCHAR(16) NOT NULL, predicate VARCHAR(80) NOT NULL,
    chunk_id INT NOT NULL, payload VARBINARY(16384) NOT NULL)
ORDER BY tenant_id, snapshot_id, domain, chunk_id, predicate
SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES
PARTITION BY (chunk_id // :per_partition);
INSERT /*+DIRECT*/ INTO bitmap_bench.bitmap_index_parts
SELECT tenant_id, snapshot_id, domain, predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
WHERE tenant_id = :tenant AND snapshot_id = :snapshot AND domain = 'person';
COMMIT;
SELECT ANALYZE_STATISTICS('bitmap_bench.bitmap_index_parts');
SELECT 'summary: table=bitmap_index_parts rows=' || SUM(total_row_count) || ' containers=' || COUNT(*) || ' bytes=' || SUM(used_bytes)
FROM v_monitor.storage_containers WHERE schema_name = 'bitmap_bench' AND projection_name LIKE 'bitmap_index_parts%';

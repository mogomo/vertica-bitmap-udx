-- Target tables of the "audience kept in the database" tests (bench/workloads/clickhouse_ids.sql).
DROP TABLE IF EXISTS xbench.saved_set;
DROP TABLE IF EXISTS xbench.saved_ids;
CREATE TABLE xbench.saved_set (audience LowCardinality(String), bm AggregateFunction(groupBitmap, UInt32))
ENGINE = MergeTree ORDER BY audience;
CREATE TABLE xbench.saved_ids (audience LowCardinality(String), entity_id UInt32)
ENGINE = MergeTree ORDER BY (audience, entity_id);

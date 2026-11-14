-- Target tables of the "audience kept in the database" tests (bench/workloads/vertica_ids.sql):
-- an audience saved as a set (one row per chunk) and as a table of IDs. Dropped and created anew.
DROP SCHEMA IF EXISTS bitmap_bench CASCADE;
CREATE SCHEMA bitmap_bench;
CREATE TABLE bitmap_bench.saved_set (
    audience VARCHAR(40) NOT NULL, chunk_id INT NOT NULL, payload VARBINARY(16384) NOT NULL)
ORDER BY audience, chunk_id SEGMENTED BY HASH(chunk_id) ALL NODES;
CREATE TABLE bitmap_bench.saved_ids (audience VARCHAR(40) NOT NULL, entity_id INT NOT NULL)
ORDER BY audience, entity_id SEGMENTED BY HASH(entity_id) ALL NODES;

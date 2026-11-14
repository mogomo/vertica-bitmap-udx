-- Ground probes (milestone M0): what the server and the SDK actually do.
-- Run after "make probe probe-deploy":  vsql -X -f tests/probe/probes.sql
-- Leaves schema bitmap_probe behind; "make probe-undeploy" removes it.
-- The answers recorded for Vertica 26.3.0-2 are in the comments marked "26.3:".

\echo == V1 bitwise operators on VARBINARY
-- 26.3: 000f 0fff 0ff0 f0f0
SELECT TO_HEX(HEX_TO_BINARY('0x0F0F') & HEX_TO_BINARY('0x00FF')) AS and_,
       TO_HEX(HEX_TO_BINARY('0x0F0F') | HEX_TO_BINARY('0x00FF')) AS or_,
       TO_HEX(HEX_TO_BINARY('0x0F0F') # HEX_TO_BINARY('0x00FF')) AS xor_,
       TO_HEX(~ HEX_TO_BINARY('0x0F0F')) AS not_;
-- 26.3: 000f00 (the shorter value is extended with zero bytes on the right)
SELECT TO_HEX(HEX_TO_BINARY('0x0F0F0F') & HEX_TO_BINARY('0x00FF'));
-- 26.3: 8192, 0a0a0a (full width kept)
SELECT LENGTH(x), TO_HEX(SUBSTR(x, 8190, 3)) FROM (SELECT REPEAT(HEX_TO_BINARY('0xAA'), 8192)::VARBINARY(8192)
       & REPEAT(HEX_TO_BINARY('0x0F'), 8192)::VARBINARY(8192) AS x) t;
-- 26.3: 0310 0100 0310
SELECT TO_HEX(BIT_OR(b)), TO_HEX(BIT_AND(b)), TO_HEX(BIT_XOR(b)) FROM (SELECT HEX_TO_BINARY('0x0100') b
       UNION ALL SELECT HEX_TO_BINARY('0x0300') UNION ALL SELECT HEX_TO_BINARY('0x0110')) t;
-- 26.3: 8192, 8181
SELECT LENGTH(BIT_OR(b)), TO_HEX(SUBSTR(BIT_OR(b), 8191, 2)) FROM (SELECT REPEAT(HEX_TO_BINARY('0x01'), 8192)::VARBINARY(8192) b
       UNION ALL SELECT REPEAT(HEX_TO_BINARY('0x80'), 8192)::VARBINARY(8192)) t;
-- 26.3: 8, 65536, 262144 (BITCOUNT is the native population count)
SELECT BITCOUNT(HEX_TO_BINARY('0x0F0F')), BITCOUNT(REPEAT(HEX_TO_BINARY('0xFF'), 8192)::VARBINARY(8192)),
       BITCOUNT(REPEAT(HEX_TO_BINARY('0xFF'), 32768)::VARBINARY(32768));
-- 26.3: refused, no bitwise operator on LONG VARBINARY
SELECT TO_HEX(HEX_TO_BINARY('0x01')::LONG VARBINARY & HEX_TO_BINARY('0x03')::LONG VARBINARY);

\echo == V5 maximum VARBINARY width
-- 26.3: ERROR 3852 Length for type varbinary cannot exceed 65000
CREATE LOCAL TEMP TABLE probe_w (b VARBINARY(65001)) ON COMMIT PRESERVE ROWS;

\echo == V6 bitmap functions in the catalog (built-ins are not listed in user_functions)
-- 26.3: 0 rows
SELECT DISTINCT schema_name, function_name FROM user_functions
 WHERE function_name ILIKE '%bitmap%' OR function_name ILIKE '%roaring%' OR function_name ILIKE '%bitset%';

\echo == V7 approximate distinct counts
-- 26.3: 2, 2, 2
SELECT APPROXIMATE_COUNT_DISTINCT(x), APPROXIMATE_COUNT_DISTINCT(x, 1.0)
  FROM (SELECT 1 x UNION ALL SELECT 2 UNION ALL SELECT 2) t;
SELECT APPROXIMATE_COUNT_DISTINCT_OF_SYNOPSIS(s) FROM (SELECT g, APPROXIMATE_COUNT_DISTINCT_SYNOPSIS(x) s
  FROM (SELECT 1 g, 1 x UNION ALL SELECT 2, 2 UNION ALL SELECT 2, 1) t GROUP BY g) u;

\echo == V10 fenced C++ scalar built with the SDK flags
-- 26.3: 8, NULL
SELECT bitmap_probe.probe_popcount(HEX_TO_BINARY('0x0F0F')), bitmap_probe.probe_popcount(NULL::VARBINARY);
SELECT function_name, is_fenced FROM user_functions WHERE schema_name = 'bitmap_probe' ORDER BY 1;

\echo == V2 aggregate functions
-- 26.3: 2 (unfenced)
SELECT bitmap_probe.probe_count(x) FROM (SELECT 1 x UNION ALL SELECT NULL UNION ALL SELECT 3) t;
-- 26.3: syntax error at FENCED; aggregates run unfenced only
CREATE OR REPLACE AGGREGATE FUNCTION bitmap_probe.probe_count_f AS LANGUAGE 'C++'
    NAME 'ProbeCountFactory' LIBRARY bitmap_probe.vbitmap_probe FENCED;

\echo == V3 transform: output rows differ from input rows; parameter length
DROP TABLE IF EXISTS bitmap_probe.idx CASCADE;
CREATE TABLE bitmap_probe.idx (tenant_id INT NOT NULL, domain VARCHAR(16) NOT NULL, predicate VARCHAR(80) NOT NULL,
       chunk_id INT NOT NULL, payload VARBINARY(16384) NOT NULL)
  ORDER BY tenant_id, domain, chunk_id, predicate SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES;
INSERT INTO bitmap_probe.idx SELECT 1, 'person', 'p' || (i % 5), i // 5, REPEAT(HEX_TO_BINARY('0x01'), 100)
  FROM (SELECT ROW_NUMBER() OVER () - 1 AS i FROM (SELECT 1 FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
        UNION ALL SELECT '2000-01-01 00:00:49'::TIMESTAMP) b TIMESERIES ts AS '1 second' OVER (ORDER BY t)) x) g;
COMMIT;
-- 26.3: 10 partitions of 5 rows each, one output row each; expr_len 60000
SELECT COUNT(*), MAX(rows_read), MAX(expr_len) FROM (SELECT bitmap_probe.probe_partition(chunk_id, payload
       USING PARAMETERS expr = REPEAT('x', 60000)) OVER (PARTITION BY chunk_id) FROM bitmap_probe.idx) t;
-- 26.3: 65000 for both: a value is at most the declared 65000 characters long
SELECT MAX(expr_len) FROM (SELECT bitmap_probe.probe_partition(chunk_id, payload
       USING PARAMETERS expr = REPEAT('x', 65001)) OVER (PARTITION BY chunk_id) FROM bitmap_probe.idx) t;
SELECT MAX(expr_len) FROM (SELECT bitmap_probe.probe_partition(chunk_id, payload
       USING PARAMETERS expr = REPEAT('x', 200000)) OVER (PARTITION BY chunk_id) FROM bitmap_probe.idx) t;

\echo == V4 plan of a transform partitioned by the segmentation columns
-- 26.3, single node: "Group Local Resegment" and a Sort step, with either projection order
EXPLAIN SELECT bitmap_probe.probe_partition(chunk_id, payload) OVER (PARTITION BY tenant_id, domain, chunk_id)
  FROM bitmap_probe.idx WHERE tenant_id = 1 AND domain = 'person';

\echo == V5 / V8 memory grant by declared width; cost per call on 8 KB values
DROP TABLE IF EXISTS bitmap_probe.w8, bitmap_probe.w16, bitmap_probe.w65 CASCADE;
CREATE TABLE bitmap_probe.w8  (chunk_id INT NOT NULL, b VARBINARY(8192)  NOT NULL) ORDER BY chunk_id SEGMENTED BY HASH(chunk_id) ALL NODES;
CREATE TABLE bitmap_probe.w16 (chunk_id INT NOT NULL, b VARBINARY(16384) NOT NULL) ORDER BY chunk_id SEGMENTED BY HASH(chunk_id) ALL NODES;
CREATE TABLE bitmap_probe.w65 (chunk_id INT NOT NULL, b VARBINARY(65000) NOT NULL) ORDER BY chunk_id SEGMENTED BY HASH(chunk_id) ALL NODES;
INSERT /*+direct*/ INTO bitmap_probe.w8 SELECT i, REPEAT(HEX_TO_BINARY('0x5A'), 8192)
  FROM (SELECT ROW_NUMBER() OVER () AS i FROM
        (SELECT 1 FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t UNION ALL SELECT '2000-01-01 23:59:59'::TIMESTAMP) b
         TIMESERIES ts AS '1 second' OVER (ORDER BY t)) x CROSS JOIN
        (SELECT 1 FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t UNION ALL SELECT '2000-01-01 00:00:09'::TIMESTAMP) b
         TIMESERIES ts AS '1 second' OVER (ORDER BY t)) y LIMIT 100000) g;
INSERT /*+direct*/ INTO bitmap_probe.w16 SELECT * FROM bitmap_probe.w8;
INSERT /*+direct*/ INTO bitmap_probe.w65 SELECT * FROM bitmap_probe.w8;
COMMIT;
CREATE OR REPLACE FUNCTION bitmap_probe.probe_popcount_u AS LANGUAGE 'C++'
    NAME 'ProbePopcountFactory' LIBRARY bitmap_probe.vbitmap_probe NOT FENCED;
SELECT /*+label(probe_v5_8)*/  SUM(bytes_read) FROM (SELECT bitmap_probe.probe_partition(chunk_id // 100, b) OVER (PARTITION BY chunk_id // 100) FROM bitmap_probe.w8) t;
SELECT /*+label(probe_v5_16)*/ SUM(bytes_read) FROM (SELECT bitmap_probe.probe_partition(chunk_id // 100, b) OVER (PARTITION BY chunk_id // 100) FROM bitmap_probe.w16) t;
SELECT /*+label(probe_v5_65)*/ SUM(bytes_read) FROM (SELECT bitmap_probe.probe_partition(chunk_id // 100, b) OVER (PARTITION BY chunk_id // 100) FROM bitmap_probe.w65) t;
-- 26.3: the same memory_acquired_mb for the three widths (the general pool's per-query budget)
SELECT request_label, memory_acquired_mb, request_duration_ms FROM v_monitor.query_requests
 WHERE request_label LIKE 'probe_v5_%' ORDER BY start_timestamp DESC LIMIT 3;
\timing on
SELECT SUM(BITCOUNT(b)) FROM bitmap_probe.w8;
SELECT SUM(bitmap_probe.probe_popcount_u(b)) FROM bitmap_probe.w8;
SELECT SUM(bitmap_probe.probe_popcount(b)) FROM bitmap_probe.w8;
\timing off

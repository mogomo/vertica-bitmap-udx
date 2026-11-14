#!/usr/bin/env bash
# Function semantics in SQL: boundary IDs, duplicates, empty / sparse / dense / full sets, NULL
# rules, every error case, chunk widths, and set algebra against native SQL on random data.
#
#   tests/sql/test_semantics.sh
#
# Drops and recreates schema bitmap_test. Needs the functions installed (make deploy).
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh

# rows N: SQL for a table (i) with the integers 0 to N-1 (N up to 864,000).
rows() {
    echo "(SELECT ROW_NUMBER() OVER () - 1 AS i FROM (SELECT 1 FROM
            (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t UNION ALL SELECT '2000-01-10 23:59:59'::TIMESTAMP) b
            TIMESERIES ts AS '1 second' OVER (ORDER BY t)) x LIMIT $1)"
}

# Builds payloads of the IDs in table bitmap_test.$1 (column e) as set $2 into bitmap_test.sets.
build_set() {
    run_sql "INSERT INTO bitmap_test.sets
               SELECT vbitmap.bm_build(name, chunk_id, local_id${3:+ USING PARAMETERS chunk_bits = $3})
                      OVER (PARTITION BY name, chunk_id)
               FROM (SELECT '$2'::VARCHAR(20) AS name, e >> ${3:-16} AS chunk_id, e & ((1 << ${3:-16}) - 1) AS local_id
                     FROM bitmap_test.$1) m;
             COMMIT;" > /dev/null
}

echo "== setup"
run_sql "DROP SCHEMA IF EXISTS bitmap_test CASCADE;" > /dev/null
run_sql "CREATE SCHEMA bitmap_test;
         CREATE TABLE bitmap_test.sets (name VARCHAR(20) NOT NULL, chunk_id INT NOT NULL, payload VARBINARY(65000) NOT NULL);
         CREATE TABLE bitmap_test.boundary (e INT NOT NULL);
         INSERT INTO bitmap_test.boundary
           SELECT 0 UNION ALL SELECT 65535 UNION ALL SELECT 65536 UNION ALL SELECT 4294967295
           UNION ALL SELECT 4294967296 UNION ALL SELECT 9223372036854775807
           UNION ALL SELECT 0 UNION ALL SELECT 65536;
         CREATE TABLE bitmap_test.full_chunk AS SELECT i AS e FROM $(rows 65536) r;
         CREATE TABLE bitmap_test.half_chunk AS SELECT i * 2 AS e FROM $(rows 32768) r;
         CREATE TABLE bitmap_test.rand_a AS SELECT DISTINCT HASH(i, 11) % 1048576 AS e FROM $(rows 200000) r;
         CREATE TABLE bitmap_test.rand_b AS SELECT DISTINCT HASH(i, 22) % 1048576 AS e FROM $(rows 50000) r
                                            UNION SELECT i FROM $(rows 70000) r;
         COMMIT;" > /dev/null
build_set boundary boundary
build_set full_chunk full
build_set half_chunk half
build_set rand_a a
build_set rand_b b
build_set rand_a a18 18

echo "== boundary IDs"
expect_eq "round trip of 0, 65535, 65536, 2^32-1, 2^32, 2^63-1 (duplicates once)" \
  "0 65535 65536 4294967295 4294967296 9223372036854775807" \
  "SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS e FROM bitmap_test.sets WHERE name = 'boundary' ORDER BY 1;"
expect_eq "chunks of the boundary IDs (2^32 is chunk 65536, not 0)" "0|2 1|1 65535|1 65536|1 140737488355327|1" \
  "SELECT chunk_id, vbitmap.bm_cardinality(payload) FROM bitmap_test.sets WHERE name = 'boundary' ORDER BY 1;"
expect_eq "bm_contains on boundary local IDs 0 and 65535" "t|t|f" \
  "SELECT vbitmap.bm_contains(payload, 0), vbitmap.bm_contains(payload, 65535), vbitmap.bm_contains(payload, 1)
   FROM bitmap_test.sets WHERE name = 'boundary' AND chunk_id = 0;"

echo "== empty, sparse, dense, full"
expect_eq "empty set" "0|codec=empty chunk_bits=16 cardinality=0 bytes=16" \
  "SELECT vbitmap.bm_cardinality(vbitmap.bm_empty()), vbitmap.bm_info(vbitmap.bm_empty());"
expect_eq "full chunk is one Roaring run" "65536|codec=roaring" \
  "SELECT vbitmap.bm_cardinality(payload), SPLIT_PART(vbitmap.bm_info(payload), ' ', 1) FROM bitmap_test.sets WHERE name = 'full';"
expect_eq "every other ID: raw bitset of 8,208 bytes" "32768|codec=raw|8208" \
  "SELECT vbitmap.bm_cardinality(payload), SPLIT_PART(vbitmap.bm_info(payload), ' ', 1), LENGTH(payload) FROM bitmap_test.sets WHERE name = 'half';"
expect_eq "full AND empty = empty; full OR empty = full" "0|65536" \
  "SELECT vbitmap.bm_cardinality(vbitmap.bm_and(payload, vbitmap.bm_empty())), vbitmap.bm_cardinality(vbitmap.bm_or(payload, vbitmap.bm_empty()))
   FROM bitmap_test.sets WHERE name = 'full';"
expect_eq "full ANDNOT half = the odd IDs" "32768|f|t" \
  "SELECT vbitmap.bm_cardinality(d), vbitmap.bm_contains(d, 0), vbitmap.bm_contains(d, 1)
   FROM (SELECT vbitmap.bm_andnot(f.payload, h.payload) AS d FROM bitmap_test.sets f JOIN bitmap_test.sets h ON h.name = 'half'
         WHERE f.name = 'full') x;"

echo "== NULL rules"
expect_eq "NULL in, NULL out" "t|t|t|t|t|t|t|t" \
  "SELECT vbitmap.bm_and(NULL, vbitmap.bm_empty()) IS NULL, vbitmap.bm_or(vbitmap.bm_empty(), NULL) IS NULL,
          vbitmap.bm_xor(NULL, NULL) IS NULL, vbitmap.bm_andnot(NULL, vbitmap.bm_empty()) IS NULL,
          vbitmap.bm_cardinality(NULL) IS NULL, vbitmap.bm_and_cardinality(NULL, vbitmap.bm_empty()) IS NULL,
          vbitmap.bm_contains(NULL, 1) IS NULL, vbitmap.bm_contains(vbitmap.bm_empty(), NULL) IS NULL;"
expect_eq "bm_union skips NULL payloads" "2" \
  "SELECT vbitmap.bm_cardinality(payload) FROM (
     SELECT vbitmap.bm_union(k, p) OVER (PARTITION BY k) FROM (
       SELECT 1 AS k, payload AS p FROM bitmap_test.sets WHERE name = 'boundary' AND chunk_id = 0
       UNION ALL SELECT 1, NULL::VARBINARY) s) u;"

echo "== errors"
expect_error "NULL local ID"               "NULL local ID" \
  "SELECT vbitmap.bm_build(1, NULL::INT) OVER (PARTITION BY 1);"
expect_error "local ID outside the chunk"  "outside a chunk of 16 bits" \
  "SELECT vbitmap.bm_build(1, 65536) OVER (PARTITION BY 1);"
expect_error "negative local ID"           "local ID -1 is outside" \
  "SELECT vbitmap.bm_build(1, -1) OVER (PARTITION BY 1);"
expect_error "keys differ in a partition"  "key values differ" \
  "SELECT vbitmap.bm_build(name, chunk_id, 1) OVER (PARTITION BY name) FROM bitmap_test.sets WHERE name = 'boundary';"
expect_error "chunk_bits out of range"     "chunk_bits must be between 8 and 18" \
  "SELECT vbitmap.bm_build(1, 1 USING PARAMETERS chunk_bits = 19) OVER (PARTITION BY 1);"
expect_error "malformed payload: bm_cardinality" "invalid bitmap payload" \
  "SELECT vbitmap.bm_cardinality(HEX_TO_BINARY('0x00'));"
expect_error "truncated payload: bm_and"   "invalid bitmap payload" \
  "SELECT vbitmap.bm_and(SUBSTR(payload, 1, 20), payload) FROM bitmap_test.sets WHERE name = 'boundary' AND chunk_id = 0;"
expect_error "damaged payload: bm_to_ids"  "checksum mismatch" \
  "SELECT vbitmap.bm_to_ids(chunk_id, SUBSTR(payload, 1, 19) || HEX_TO_BINARY('0xFF') || SUBSTR(payload, 21)) OVER (PARTITION ROW)
   FROM bitmap_test.sets WHERE name = 'boundary' AND chunk_id = 0;"
expect_error "damaged payload: bm_union"   "invalid bitmap payload" \
  "SELECT vbitmap.bm_union(1, HEX_TO_BINARY('0x56424D31')) OVER (PARTITION BY 1);"
expect_error "bm_contains local ID out of range" "outside a chunk of 16 bits" \
  "SELECT vbitmap.bm_contains(payload, 65536) FROM bitmap_test.sets WHERE name = 'full';"
expect_error "different chunk widths"      "different chunk widths" \
  "SELECT vbitmap.bm_and(a.payload, b.payload) FROM bitmap_test.sets a JOIN bitmap_test.sets b ON a.chunk_id = b.chunk_id
   WHERE a.name = 'a' AND b.name = 'a18' AND a.chunk_id = 0;"
# Eight sparse 18-bit parts fit VARBINARY(16384); their union is a 32,784-byte raw payload.
expect_error "18-bit union does not fit a 16384-byte output" "exceeds the output width" \
  "SELECT vbitmap.bm_union(c, p) OVER (PARTITION BY c) FROM (
     SELECT chunk_id AS c, payload::VARBINARY(16384) AS p FROM (
       SELECT vbitmap.bm_build(chunk_id, part, local_id USING PARAMETERS chunk_bits = 18) OVER (PARTITION BY chunk_id, part)
       FROM (SELECT e >> 18 AS chunk_id, e % 8 AS part, e & 262143 AS local_id FROM bitmap_test.rand_a) m) b) n;"
expect_error "an 18-bit payload cut to 16384 bytes is rejected, not misread" "raw body of 16368 bytes" \
  "SELECT vbitmap.bm_cardinality(payload::VARBINARY(16384)) FROM bitmap_test.sets WHERE name = 'a18' AND chunk_id = 0;"

echo "== chunk widths"
ids16="SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) FROM bitmap_test.sets WHERE name = 'a'"
ids18="SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) FROM bitmap_test.sets WHERE name = 'a18'"
expect_eq "18-bit chunks: no ID of the 16-bit set missing" "0" "$(set_diff_sql "$ids16" "$ids18")"
expect_eq "18-bit chunks: no extra ID"                     "0" "$(set_diff_sql "$ids18" "$ids16")"
expect_eq "18-bit chunks: 4 times fewer payloads"          "16|4" \
  "SELECT SUM(CASE WHEN name = 'a' THEN 1 ELSE 0 END), SUM(CASE WHEN name = 'a18' THEN 1 ELSE 0 END) FROM bitmap_test.sets;"
expect_eq "empty set of 16 bits combines with an 18-bit set" "t" \
  "SELECT vbitmap.bm_cardinality(vbitmap.bm_or(payload, vbitmap.bm_empty())) = vbitmap.bm_cardinality(payload)
   FROM bitmap_test.sets WHERE name = 'a18' AND chunk_id = 0;"

echo "== set algebra against native SQL (random sets over 16 chunks)"
for op in and or xor andnot; do
    case $op in
        and)    native="(SELECT e FROM bitmap_test.rand_a INTERSECT SELECT e FROM bitmap_test.rand_b)" ;;
        or)     native="(SELECT e FROM bitmap_test.rand_a UNION SELECT e FROM bitmap_test.rand_b)" ;;
        xor)    native="((SELECT e FROM bitmap_test.rand_a EXCEPT SELECT e FROM bitmap_test.rand_b) UNION (SELECT e FROM bitmap_test.rand_b EXCEPT SELECT e FROM bitmap_test.rand_a))" ;;
        andnot) native="(SELECT e FROM bitmap_test.rand_a EXCEPT SELECT e FROM bitmap_test.rand_b)" ;;
    esac
    # FULL JOIN: a chunk present in one set only is combined with the empty set.
    bitmap="(SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS e FROM (
               SELECT COALESCE(a.chunk_id, b.chunk_id) AS chunk_id,
                      vbitmap.bm_$op(COALESCE(a.payload, vbitmap.bm_empty()), COALESCE(b.payload, vbitmap.bm_empty())) AS payload
               FROM (SELECT * FROM bitmap_test.sets WHERE name = 'a') a
               FULL JOIN (SELECT * FROM bitmap_test.sets WHERE name = 'b') b ON a.chunk_id = b.chunk_id) x)"
    expect_eq "bm_$op: no native ID missing" "0" "$(set_diff_sql "$native" "$bitmap")"
    expect_eq "bm_$op: no extra ID"          "0" "$(set_diff_sql "$bitmap" "$native")"
done
expect_eq "bm_and_cardinality = native intersection count" "t" \
  "SELECT (SELECT SUM(vbitmap.bm_and_cardinality(a.payload, b.payload)) FROM bitmap_test.sets a
           JOIN bitmap_test.sets b ON b.chunk_id = a.chunk_id AND b.name = 'b' WHERE a.name = 'a')
        = (SELECT COUNT(*) FROM (SELECT e FROM bitmap_test.rand_a INTERSECT SELECT e FROM bitmap_test.rand_b) i);"
expect_eq "bm_cardinality = native count" "t" \
  "SELECT (SELECT SUM(vbitmap.bm_cardinality(payload)) FROM bitmap_test.sets WHERE name = 'a') = (SELECT COUNT(*) FROM bitmap_test.rand_a);"

run_sql "DROP SCHEMA bitmap_test CASCADE;" > /dev/null
finish_tests test_semantics

#!/usr/bin/env bash
# Fixture test: loads the fixture into a fresh schema bitmap_demo, builds and publishes the index
# through the lifecycle (scripts/snapshot.sh), and checks every query of sql/queries on the native
# and the bitmap path: the expected answer on both, and the same set of rows in both directions.
#
#   tests/sql/test_fixture.sh
#
# Drops and recreates schema bitmap_demo. Needs the functions installed (make deploy).
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh

echo "== setup"
setup_fixture || exit 1
# Test snapshot 9 of tenant 1: snapshot 1 plus person 8 whose suspension is unknown (NULL). Built
# and verified, not published.
run_sql "INSERT INTO bitmap_demo.user_profile
           SELECT tenant_id, 9, entity_id, country, age, consent, suspended FROM bitmap_demo.user_profile
           WHERE tenant_id = 1 AND snapshot_id = 1
           UNION ALL SELECT 1, 9, 8, 'IL', 30, true, NULL;
         INSERT INTO bitmap_demo.user_interest
           SELECT tenant_id, 9, entity_id, topic FROM bitmap_demo.user_interest WHERE tenant_id = 1 AND snapshot_id = 1
           UNION ALL SELECT 1, 9, 8, 'sports';
         COMMIT;" > /dev/null
scripts/snapshot.sh build --tenant=1 --domain=person --snapshot=9 --watermark="$FIX_WM_PERSON" --deep > /dev/null || exit 1
expect_eq "manifest after setup" \
  "1|asset|1|active 1|device|1|active 1|person|1|active 1|person|9|verified 2|person|1|active" \
  "SELECT tenant_id, domain, snapshot_id, state FROM bitmap_demo.bitmap_snapshot ORDER BY 1, 2, 3;"

echo "== predicates built (every family definition read completely, including multi-line ones)"
expect_eq "person predicates of tenant 1 snapshot 1 with cardinalities" \
  "age_25_54|age_band|5 age_known|age_band|6 all|universe|7 consent_true|consent|7 country_IL|country|6 country_US|country|1 suspended_false|suspended|6 suspended_true|suspended|1 topic_finance|topic|3 topic_sports|topic|5" \
  "SELECT predicate, family, cardinality FROM bitmap_demo.bitmap_predicate
   WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person' ORDER BY 1;"
expect_eq "asset and device predicates of tenant 1" \
  "asset|6 device|5" \
  "SELECT domain, COUNT(*) FROM bitmap_demo.bitmap_predicate WHERE tenant_id = 1 AND snapshot_id = 1 AND domain <> 'person' GROUP BY 1 ORDER BY 1;"
expect_eq "bitmap_predicate matches bitmap_index" "0" \
  "SELECT COUNT(*) FROM (SELECT tenant_id, snapshot_id, domain, predicate, COUNT(*) AS c FROM bitmap_demo.bitmap_index GROUP BY 1, 2, 3, 4
                         EXCEPT SELECT tenant_id, snapshot_id, domain, predicate, chunks FROM bitmap_demo.bitmap_predicate) d;"

echo "== Q1 audience"
expect_query    "q1 native ids"   q1/native_ids   1 1 "1 65536 4294967296"
expect_query    "q1 bitmap ids"   q1/bitmap_ids   1 1 "1 65536 4294967296"
expect_same_set "q1 same set"     q1/native_ids q1/bitmap_ids 1 1
expect_query    "q1 native count" q1/native_count 1 1 "3"
expect_query    "q1 bitmap count" q1/bitmap_count 1 1 "3"

echo "== Q2 distinct users, Q2b roll-up"
expect_query    "q2 native"        q2/native        1 1 "3"
expect_query    "q2 bitmap"        q2/bitmap        1 1 "3"
expect_query    "q2 native daily"  q2/native_daily  1 1 "2026-11-01|2 2026-11-02|2"
expect_query    "q2 bitmap daily"  q2/bitmap_daily  1 1 "2026-11-01|2 2026-11-02|2"
expect_query    "q2b native"       q2b/native       1 1 "4"
expect_query    "q2b bitmap"       q2b/bitmap       1 1 "4"

echo "== Q3 facets"
expect_query    "q3 native"   q3/native 1 1 "topic_finance|1 topic_sports|2"
expect_query    "q3 bitmap"   q3/bitmap 1 1 "topic_finance|1 topic_sports|2"
expect_same_set "q3 same set" q3/native q3/bitmap 1 1

echo "== Q4 devices, Q5 assets"
expect_query    "q4 native"   q4/native 1 1 "10" "$FIX_WM_DEVICE"
expect_query    "q4 bitmap"   q4/bitmap 1 1 "10"
expect_same_set "q4 same set" q4/native q4/bitmap 1 1 "$FIX_WM_DEVICE"
expect_query    "q5 native"   q5/native 1 1 "100"
expect_query    "q5 bitmap"   q5/bitmap 1 1 "100"
expect_same_set "q5 same set" q5/native q5/bitmap 1 1

echo "== Q8 exclusion and the NULL trap"
expect_query    "q8 native"          q8/native      1 1 "1 2 7 4294967296"
expect_query    "q8 bitmap"          q8/bitmap      1 1 "1 2 7 4294967296"
expect_same_set "q8 same set"        q8/native q8/bitmap 1 1
expect_query    "q8 trap native s1"  q8/native_trap 1 1 "6|6"
expect_query    "q8 trap bitmap s1"  q8/bitmap_trap 1 1 "6|6"
expect_query    "q8 trap native s9"  q8/native_trap 1 9 "7|6"
expect_query    "q8 trap bitmap s9"  q8/bitmap_trap 1 9 "7|6"
expect_query    "q1 bitmap ids s9 (NULL suspension excluded)" q1/bitmap_ids 1 9 "1 65536 4294967296"
expect_same_set "q1 same set s9"     q1/native_ids q1/bitmap_ids 1 9

echo "== tenant isolation (tenant 2: same IDs, other attributes; built via bitmap_membership)"
expect_query    "q1 native ids t2" q1/native_ids 2 1 "2 3"
expect_query    "q1 bitmap ids t2" q1/bitmap_ids 2 1 "2 3"
expect_same_set "q1 same set t2"   q1/native_ids q1/bitmap_ids 2 1
expect_query    "q8 bitmap t2"     q8/bitmap     2 1 "2"
expect_query    "q2 bitmap t2 (no daily sets built)" q2/bitmap 2 1 "0"

echo "== build paths give identical payloads (direct and via bitmap_membership)"
# Snapshot 99 is built outside the manifest from source snapshot 9 and removed again.
scripts/build_index.sh --tenant=1 --snapshot=99 --source-snapshot=9 --domain=person --via-membership > /dev/null
expect_eq "direct = via membership" "0 0 10" \
  "SELECT (SELECT COUNT(*) FROM (SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 9
                                 EXCEPT SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 99) a)
          || ' ' ||
          (SELECT COUNT(*) FROM (SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 99
                                 EXCEPT SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 9) b)
          || ' ' || (SELECT COUNT(DISTINCT predicate) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 9);"
run_sql "DELETE FROM bitmap_demo.bitmap_index WHERE snapshot_id = 99; DELETE FROM bitmap_demo.bitmap_membership WHERE snapshot_id = 99;
         DELETE FROM bitmap_demo.bitmap_predicate WHERE snapshot_id = 99; COMMIT;" > /dev/null
expect_eq "one row per index key" "0" \
  "SELECT COUNT(*) FROM (SELECT tenant_id, snapshot_id, domain, predicate, chunk_id FROM bitmap_demo.bitmap_index
                         GROUP BY 1, 2, 3, 4, 5 HAVING COUNT(*) > 1) d;"
expect_cmd "build_index.sh refuses to overwrite without --replace" fail "already has rows" \
  scripts/build_index.sh --tenant=1 --snapshot=1 --domain=person
expect_cmd "snapshot.sh refuses to rebuild a published snapshot" fail "is active: a built snapshot is never changed" \
  scripts/snapshot.sh build --tenant=1 --domain=person --snapshot=1 --watermark="$FIX_WM_PERSON"

finish_tests test_fixture

#!/usr/bin/env bash
# Bit-sliced sets (sql/families_bitsliced.sql): a numeric attribute stored as one set per bit, so
# that its total over any audience comes from set counts alone, without a join.
#
#   tests/sql/test_bitsliced.sh [--keep]
#
# Uses the fixture of tests/sql/test_fixture.sh in bitmap_demo (loads it if bitmap_demo is missing).
# Adds the family age_bits to tenant 1, builds person snapshot 8 through the lifecycle from a copy of
# source snapshot 1 with ages 0, 255, an unknown age and a person in another chunk, and compares
# people / known ages / sum of ages with native SQL for several audiences. Removes the family and
# its snapshots at the end unless --keep.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh
KEEP=no; [ "${1:-}" = --keep ] && KEEP=yes
SNAP=scripts/snapshot.sh

if [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'bitmap_predicate';")" != 1 ]; then
    echo "== bitmap_demo missing: loading the fixture"
    tests/sql/test_fixture.sh > /dev/null || exit 1
fi

cleanup() {
    for s in 7 8; do
        $SNAP discard --tenant=1 --domain=person --snapshot=$s > /dev/null 2>&1
        run_sql "DELETE FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id = $s;
                 DELETE FROM bitmap_demo.user_interest WHERE tenant_id = 1 AND snapshot_id = $s; COMMIT;" > /dev/null
    done
    run_sql "DELETE FROM bitmap_demo.bitmap_family WHERE tenant_id = 1 AND family = 'age_bits'; COMMIT;" > /dev/null
}
# copy_source TO: person source snapshot TO of tenant 1 = snapshot 1.
copy_source() {
    run_sql "INSERT INTO bitmap_demo.user_profile SELECT tenant_id, $1, entity_id, country, age, consent, suspended
               FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id = 1;
             INSERT INTO bitmap_demo.user_interest SELECT tenant_id, $1, entity_id, topic
               FROM bitmap_demo.user_interest WHERE tenant_id = 1 AND snapshot_id = 1;
             COMMIT;" > /dev/null
}
# bmq_sql MODE EXPR: the SQL bmq runs on snapshot 8, without its ORDER BY, for embedding.
bmq_sql() { scripts/bmq --echo_only --raw --snapshot=8 --mode="$1" "$2" | sed -e 's/ ORDER BY 1;$//' -e 's/;$//'; }
# sliced_sql EXPR: people | known ages | sum of ages of an audience on snapshot 8, from set counts.
sliced_sql() {
    echo "SELECT people, age_known, CASE WHEN age_known > 0 THEN bit_sum END FROM (
            SELECT COALESCE(SUM(CASE WHEN predicate = 'all' THEN cnt END), 0) AS people,
                   COALESCE(SUM(CASE WHEN predicate = 'age_known' THEN cnt END), 0) AS age_known,
                   COALESCE(SUM(CASE WHEN predicate LIKE 'age\\_bit\\_%' THEN cnt * (1 << SPLIT_PART(predicate, '_', 3)::INT) END), 0) AS bit_sum
            FROM (SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS expr = '$1', facets = '') OVER (PARTITION BY chunk_id)
                  FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 8 AND domain = 'person') f) t;"
}
# native_sql EXPR: the same three numbers from the profile rows of the audience (bmq's native oracle).
native_sql() {
    echo "SELECT COUNT(*), COUNT(age), SUM(age) FROM bitmap_demo.user_profile
          WHERE tenant_id = 1 AND snapshot_id = 8 AND entity_id IN ($(bmq_sql native-ids "$1"));"
}

echo "== setup: family age_bits, source snapshot 8, index snapshot 8 built and validated"
cleanup
run_file sql/families_bitsliced.sql -v tenant=1 || exit 1
copy_source 8
run_sql "INSERT INTO bitmap_demo.user_profile
                   SELECT 1, 8, 9,      'IL', 0,    true, false
         UNION ALL SELECT 1, 8, 10,     'IL', 255,  true, false
         UNION ALL SELECT 1, 8, 11,     'IL', NULL, true, false
         UNION ALL SELECT 1, 8, 131077, 'IL', 90,   true, false;
         INSERT INTO bitmap_demo.user_interest
                   SELECT 1, 8, 9,      'sports'
         UNION ALL SELECT 1, 8, 10,     'sports'
         UNION ALL SELECT 1, 8, 11,     'sports'
         UNION ALL SELECT 1, 8, 11,     'finance'
         UNION ALL SELECT 1, 8, 131077, 'sports';
         COMMIT;" > /dev/null
expect_cmd "snapshot 8 with the bit-slice family builds and passes the deep validation" ok "" \
  $SNAP build --tenant=1 --domain=person --snapshot=8 --watermark="$FIX_WM_PERSON" --deep
expect_eq "snapshot 8 is verified and certifies the family" "verified|t" \
  "SELECT state, families LIKE '%age_bits%' FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = 8;"

echo "== the sets"
expect_eq "one set per bit with the people whose age has it" \
  "age_bit_0|5 age_bit_1|6 age_bit_2|2 age_bit_3|5 age_bit_4|4 age_bit_5|5 age_bit_6|3 age_bit_7|1" \
  "SELECT predicate, cardinality FROM bitmap_demo.bitmap_predicate
   WHERE tenant_id = 1 AND snapshot_id = 8 AND domain = 'person' AND family = 'age_bits' ORDER BY 1;"
expect_eq "weighted set sizes = SUM(age) of the table" \
  "$(run_sql "SELECT SUM(age) FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id = 8;")" \
  "SELECT SUM(cardinality * (1 << SPLIT_PART(predicate, '_', 3)::INT)) FROM bitmap_demo.bitmap_predicate
   WHERE tenant_id = 1 AND snapshot_id = 8 AND domain = 'person' AND family = 'age_bits';"

echo "== Q9: people, known ages and sum of ages of the Q8 audience"
expect_query "q9 native"    q9/native    1 8 "7|6|491"
expect_query "q9 bitsliced" q9/bitsliced 1 8 "7|6|491"

echo "== any audience: set counts = profile rows of the audience"
bad=0
for e in 'all' 'country_US' 'topic_finance - topic_sports' 'age_25_54 | suspended_true' \
         'country_IL & topic_sports - topic_finance' 'country_IL - age_known' 'country_US & topic_sports' \
         'age_bit_7' 'age_known - age_bit_6 - age_bit_7' \
         'age_known - age_bit_0 - age_bit_1 - age_bit_2 - age_bit_3 - age_bit_4 - age_bit_5 - age_bit_6 - age_bit_7'; do
    a=$(run_sql "$(sliced_sql "$e")"); b=$(run_sql "$(native_sql "$e")")
    if [ "$a" != "$b" ] || [ -z "$a" ]; then bad=$((bad + 1)); echo "      differs: $e -> sets $a, native $b"; fi
done
[ "$bad" = 0 ] && pass "10 audiences agree with native SQL" || fail "audiences" "0 differences" "$bad differences"
expect_eq "everyone: 11 people, 9 known ages, sum 609" "11|9|609" "$(sliced_sql all)"
expect_eq "nobody has a known age: the sum is NULL, not 0" "2|0|" "$(sliced_sql 'country_IL - age_known')"
expect_eq "age 0 only: the sum is 0, not NULL" "1|1|0" \
  "$(sliced_sql 'age_known - age_bit_0 - age_bit_1 - age_bit_2 - age_bit_3 - age_bit_4 - age_bit_5 - age_bit_6 - age_bit_7')"
expect_eq "empty audience" "0|0|" "$(sliced_sql 'country_US & topic_sports')"
expect_eq "bit slices as range predicates: younger than 64" "1 3 4 9 65536 4294967296" \
  "$(bmq_sql ids 'age_known - age_bit_6 - age_bit_7') ORDER BY 1;"

echo "== a value outside the range stops the build"
copy_source 7
run_sql "INSERT INTO bitmap_demo.user_profile SELECT 1, 7, 12, 'IL', 300, true, false; COMMIT;" > /dev/null
expect_cmd "age 300 fails the build of snapshot 7" fail "age outside 0 to 255: 300" \
  $SNAP build --tenant=1 --domain=person --snapshot=7 --watermark="$FIX_WM_PERSON"

[ "$KEEP" = yes ] || cleanup
finish_tests test_bitsliced

#!/usr/bin/env bash
# The aggregate forms of bm_build and bm_union (bm_build_agg, bm_union_agg) and the builder option
# that uses them (scripts/build_index.sh --aggregate, scripts/snapshot.sh build --aggregate).
#
#   tests/sql/test_aggregate.sh
#
# Uses the fixture of tests/sql/test_fixture.sh in bitmap_demo (loads it if bitmap_demo is missing).
# Vertica runs user-defined aggregates in the server process only: a fenced deployment has no
# aggregate functions, and this test then checks only that the builder says so. Unfenced, every
# domain of tenant 1 is built again as snapshot 11 with --aggregate and compared with snapshot 1
# byte for byte; snapshot 11 is discarded at the end.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh
SNAP=scripts/snapshot.sh

if [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'bitmap_predicate';")" != 1 ]; then
    echo "== bitmap_demo missing: loading the fixture"
    tests/sql/test_fixture.sh > /dev/null || exit 1
fi
IX="FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person'"

if [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.user_functions WHERE schema_name = 'vbitmap' AND function_name = 'bm_build_agg';")" = 0 ]; then
    echo "== fenced deployment: no aggregate functions"
    expect_cmd "--aggregate asks for an unfenced deployment" fail "needs the aggregate functions of an unfenced deployment" \
      scripts/build_index.sh --tenant=1 --snapshot=11 --source-snapshot=1 --domain=person --watermark="$FIX_WM_PERSON" --aggregate
    expect_eq "nothing was written" "0" "SELECT COUNT(*) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 11;"
    finish_tests test_aggregate
    exit 0
fi

cleanup() {
    for d in person device asset; do $SNAP discard --tenant=1 --domain=$d --snapshot=11 > /dev/null 2>&1; done
}
# same_rows NAME TABLE COLUMNS [EXTRA]: the rows of snapshot 11 equal those of snapshot 1.
same_rows() {
    local a="SELECT $3 FROM bitmap_demo.$2 WHERE tenant_id = 1 AND snapshot_id = 11 ${4:-}"
    local b="SELECT $3 FROM bitmap_demo.$2 WHERE tenant_id = 1 AND snapshot_id = 1 ${4:-}"
    expect_eq "$1" "0 0 nonempty" "$(set_diff_sql "$a" "$b") $(set_diff_sql "$b" "$a") SELECT CASE WHEN COUNT(*) > 0 THEN 'nonempty' ELSE 'EMPTY' END FROM ($a) n;"
}

echo "== the functions"
SRC=$(family_union_sql 1 1 "$FIX_WM_PERSON" person) || exit 1
AGG="SELECT predicate, entity_id >> 16 AS chunk_id, vbitmap.bm_build_agg(entity_id & 65535) AS payload FROM ($SRC) s GROUP BY 1, 2"
expect_eq "bm_build_agg GROUP BY predicate, chunk = the index built by bm_build, byte for byte" "0 0" \
  "$(set_diff_sql "$AGG" "SELECT predicate, chunk_id, payload $IX") $(set_diff_sql "SELECT predicate, chunk_id, payload $IX" "$AGG")"
EVAL="SELECT chunk_id, payload FROM (SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr = 'country_IL | country_US | topic_sports') OVER (PARTITION BY chunk_id) $IX) e"
UAGG="SELECT chunk_id, vbitmap.bm_union_agg(payload) AS payload $IX AND predicate IN ('country_IL', 'country_US', 'topic_sports') GROUP BY 1"
expect_eq "bm_union_agg GROUP BY chunk = the union evaluated by bm_eval" "0 0" "$(set_diff_sql "$UAGG" "$EVAL") $(set_diff_sql "$EVAL" "$UAGG")"
expect_eq "bm_union_agg = bm_union OVER (PARTITION BY ...)" "0" \
  "$(set_diff_sql "$UAGG" "SELECT chunk_id, payload FROM (SELECT vbitmap.bm_union(chunk_id, payload) OVER (PARTITION BY chunk_id) $IX AND predicate IN ('country_IL', 'country_US', 'topic_sports')) u")"
expect_eq "duplicates count once; a group of NULL payloads is the empty set" "3|0" \
  "SELECT (SELECT vbitmap.bm_cardinality(vbitmap.bm_build_agg(x)) FROM (SELECT 1 AS x UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 65535) t),
          (SELECT vbitmap.bm_cardinality(vbitmap.bm_union_agg(p)) FROM (SELECT NULL::VARBINARY(16384) AS p UNION ALL SELECT NULL) t);"
expect_error "a local ID outside the chunk" "local ID 65536 is outside a chunk of 16 bits" \
  "SELECT vbitmap.bm_build_agg(x) FROM (SELECT 65536 AS x) t;"
expect_error "a NULL local ID" "NULL local ID" "SELECT vbitmap.bm_build_agg(x) FROM (SELECT NULL::INT AS x) t;"
expect_error "a negative local ID" "local ID -1 is outside a chunk" "SELECT vbitmap.bm_build_agg(x) FROM (SELECT -1 AS x) t;"
expect_error "a corrupt payload" "invalid bitmap payload" "SELECT vbitmap.bm_union_agg(SUBSTR(payload, 1, 20)) $IX AND predicate = 'all';"

echo "== the builder"
cleanup
expect_cmd "person snapshot 11 with daily sets builds with --aggregate and passes the deep validation" ok "" \
  $SNAP build --tenant=1 --domain=person --snapshot=11 --source-snapshot=1 --watermark="$FIX_WM_PERSON" --daily --aggregate --deep
expect_cmd "device snapshot 11" ok "" $SNAP build --tenant=1 --domain=device --snapshot=11 --source-snapshot=1 --watermark="$FIX_WM_DEVICE" --aggregate --deep
expect_cmd "asset snapshot 11" ok "" $SNAP build --tenant=1 --domain=asset --snapshot=11 --source-snapshot=1 --watermark="$FIX_WM_ASSET" --aggregate --deep
same_rows "index rows of the three domains equal snapshot 1, byte for byte" bitmap_index "domain, predicate, chunk_id, payload"
same_rows "daily sets equal snapshot 1, byte for byte" daily_bitmap "day, channel, domain, chunk_id, payload"
same_rows "predicate list with families and sizes equals snapshot 1" bitmap_predicate "domain, family, predicate, chunks, cardinality, bytes"
expect_eq "the three snapshots are verified" "asset|verified device|verified person|verified" \
  "SELECT domain, state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND snapshot_id = 11 ORDER BY 1;"
expect_cmd "--aggregate and --via-membership exclude each other" fail "exclude each other" \
  scripts/build_index.sh --tenant=1 --snapshot=12 --source-snapshot=1 --domain=person --watermark="$FIX_WM_PERSON" --aggregate --via-membership
expect_cmd "--aggregate builds 16-bit chunks only" fail "16 bits only" \
  scripts/build_index.sh --tenant=1 --snapshot=12 --source-snapshot=1 --domain=person --watermark="$FIX_WM_PERSON" --aggregate --chunk-bits=12
expect_cmd "a negative entity ID stops the aggregate build" fail "local ID -1 is outside a chunk" \
  bash -c "printf '%s\n' \"INSERT INTO bitmap_demo.user_profile SELECT 1, 12, -3, 'IL', 30, true, false; COMMIT;\" | vsql -X -q > /dev/null;
           scripts/build_index.sh --tenant=1 --snapshot=12 --source-snapshot=12 --domain=person --watermark='$FIX_WM_PERSON' --aggregate"
run_sql "DELETE FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id = 12; COMMIT;" > /dev/null
expect_eq "the failed build wrote nothing" "0" "SELECT COUNT(*) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 12;"

cleanup
finish_tests test_aggregate

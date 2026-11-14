#!/usr/bin/env bash
# Pinned sets: bm_pin keeps a set in memory for the session, bm_member tests IDs against it on
# every scan thread, bm_unpin drops it.
#
#   tests/sql/test_pinned.sh
#
# Uses the fixture of tests/sql/test_fixture.sh in bitmap_demo (loads it if bitmap_demo is missing).
# A pinned set lives in the process that ran bm_pin. On a database with several nodes the rows of
# a segmented table are tested on every node, so there bm_member must stop with its "not in
# memory on node" error: the checks that read a table accept that error on several nodes and
# require the right answer on one.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh

if [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'bitmap_predicate';")" != 1 ]; then
    echo "== bitmap_demo missing: loading the fixture"
    tests/sql/test_fixture.sh > /dev/null || exit 1
fi
NODES=$(run_sql "SELECT COUNT(*) FROM v_catalog.nodes WHERE node_state = 'UP';")
IX="FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person'"
PROFILE="FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id = 1"
Q1='country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)'

# pin_expr EXPR NAME: evaluates and pins in one pass.
pin_expr() { echo "SELECT vbitmap.bm_pin(chunk_id, predicate, payload USING PARAMETERS expr = '$1', name = '$2') OVER () $IX;"; }
# pin_rows EXPR NAME: pins the rows of bm_eval; the NULL row makes an empty audience an empty set.
pin_rows() {
    echo "SELECT vbitmap.bm_pin(chunk_id, payload USING PARAMETERS name = '$2') OVER () FROM (
            SELECT chunk_id, payload FROM (SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr = '$1')
                                           OVER (PARTITION BY chunk_id) $IX) e
            UNION ALL SELECT NULL, NULL) r;"
}
members() { echo "SELECT entity_id $PROFILE AND vbitmap.bm_member(entity_id USING PARAMETERS name = '$1') ORDER BY 1;"; }
ids() { echo "SELECT entity_id FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = '$1') OVER (PARTITION BY chunk_id) $IX) t ORDER BY 1;"; }

# expect_table NAME EXPECTED SQL: as expect_eq; on several nodes the documented error also passes.
expect_table() {
    local out
    out=$(run_sql "$3")
    if [ "$out" = "$2" ]; then pass "$1"
    elif [ "$NODES" != 1 ] && grep -q "is not in memory on node" <<< "$out"; then pass "$1 (several nodes: reported as not in memory)"
    else fail "$1" "$2" "$out"; fi
}

echo "== pin"
expect_eq "bm_pin, expression form: members and chunks" "7|3" "$(pin_expr all a)"
expect_eq "bm_pin, payload rows: members and chunks" "3|3" "$(pin_rows "$Q1" a)"
expect_eq "an empty audience pins the empty set (expression form)" "0|0" "$(pin_expr 'all - all' a)"
expect_eq "an empty audience pins the empty set (payload rows with the NULL row)" "0|0" "$(pin_rows 'all - all' a)"
expect_eq "a saved predicate can be pinned as it is stored" "$(run_sql "SELECT cardinality || '|' || chunks FROM bitmap_demo.bitmap_predicate WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person' AND predicate = 'country_IL';")" \
  "SELECT vbitmap.bm_pin(chunk_id, payload USING PARAMETERS name = 'il') OVER () $IX AND predicate = 'country_IL';"

echo "== member"
expect_table "members of the pinned Q1 audience" "3|3 1 65536 4294967296" "$(pin_expr "$Q1" a) $(members a)"
expect_table "the same through payload rows" "3|3 1 65536 4294967296" "$(pin_rows "$Q1" b) $(members b)"
bad=0
for e in 'all' 'country_US' 'topic_finance - topic_sports' 'age_25_54 | suspended_true' \
         'country_IL & topic_sports - topic_finance' 'country_IL - age_known' 'all - all' "$Q1"; do
    a=$(run_sql "$(pin_expr "$e" x) $(members x)"); a="${a#* }"; [ "$a" = "${a#*|}" ] || a=""
    b=$(run_sql "$(ids "$e")")
    if [ "$NODES" != 1 ] && grep -q "is not in memory on node" <<< "$a"; then continue; fi
    if [ "$a" != "$b" ]; then bad=$((bad + 1)); echo "      differs: $e -> member '$a', bm_ids '$b'"; fi
done
[ "$bad" = 0 ] && pass "8 audiences: bm_member on the table = bm_ids" || fail "audiences" "0 differences" "$bad differences"
expect_table "totals of an audience through the filter = the join with its ID list" \
  "4|2 $(run_sql "SELECT COUNT(*), COUNT(age), SUM(age) $PROFILE AND entity_id IN ($(ids 'country_IL & topic_sports - topic_finance' | sed 's/ ORDER BY 1;$//'));")" \
  "$(pin_expr 'country_IL & topic_sports - topic_finance' j) SELECT COUNT(*), COUNT(age), SUM(age) $PROFILE AND vbitmap.bm_member(entity_id USING PARAMETERS name = 'j');"
expect_eq "NULL is NULL, a negative or unknown ID is not a member" "3|3 |f|t|f|f" \
  "$(pin_expr "$Q1" a) SELECT vbitmap.bm_member(NULL::INT USING PARAMETERS name = 'a'), vbitmap.bm_member(-5 USING PARAMETERS name = 'a'),
          vbitmap.bm_member(65536 USING PARAMETERS name = 'a'), vbitmap.bm_member(2 USING PARAMETERS name = 'a'),
          vbitmap.bm_member(1099511627776 USING PARAMETERS name = 'a');"
expect_eq "a name is not case sensitive; two names hold two sets" "7|3 3|3 t|f" \
  "$(pin_expr all One) $(pin_expr "$Q1" two) SELECT vbitmap.bm_member(2 USING PARAMETERS name = 'ONE'), vbitmap.bm_member(2 USING PARAMETERS name = 'two');"

echo "== lifetime"
expect_eq "pinning again under the name replaces the set" "7|3 3|3 f" \
  "$(pin_expr all a) $(pin_expr "$Q1" a) SELECT vbitmap.bm_member(2 USING PARAMETERS name = 'a');"
expect_error "another session has no such set" "this session has no set pinned as 'a'" \
  "SELECT vbitmap.bm_member(1 USING PARAMETERS name = 'a');"
expect_eq "bm_unpin drops the set once" "7|3 t f" "$(pin_expr all a) SELECT vbitmap.bm_unpin('a'); SELECT vbitmap.bm_unpin('a');"
expect_error "after bm_unpin the name is unknown" "this session has no set pinned as 'a'" \
  "$(pin_expr all a) SELECT vbitmap.bm_unpin('a'); SELECT vbitmap.bm_member(1 USING PARAMETERS name = 'a');"
# Vertica does not call a transform function that has no input row: bm_pin then returns no row and
# pins nothing, and a set pinned under the name before stays. The NULL row avoids that.
expect_eq "no input row: bm_pin returns no row, the older set of that name stays" "7|3 t" \
  "$(pin_expr all a) SELECT vbitmap.bm_pin(chunk_id, payload USING PARAMETERS name = 'a') OVER () $IX AND FALSE;
   SELECT vbitmap.bm_member(1 USING PARAMETERS name = 'a');"
expect_eq "no input row but the NULL row: the empty set replaces the older set" "7|3 0|0 f" \
  "$(pin_expr all a) SELECT vbitmap.bm_pin(chunk_id, payload USING PARAMETERS name = 'a') OVER ()
     FROM (SELECT chunk_id, payload $IX AND FALSE UNION ALL SELECT NULL, NULL) r;
   SELECT vbitmap.bm_member(1 USING PARAMETERS name = 'a');"

echo "== errors"
expect_error "name is required" "parameter 'name' is required" \
  "SELECT vbitmap.bm_pin(chunk_id, predicate, payload USING PARAMETERS expr = 'all') OVER () $IX;"
expect_error "name with other characters" "letters, digits and underscores only" "$(pin_expr all 'a b')"
expect_error "name too long" "1 to 64 characters" "$(pin_expr all "$(printf 'n%.0s' $(seq 1 65))")"
# One node: one instance sees several partitions and stops. Several nodes: each node runs an
# instance with its own chunks, and Vertica does not set a session parameter that several
# instances write (WARNING 6870), so no set is pinned under the name either way.
out=$(run_sql "SELECT vbitmap.bm_pin(chunk_id, predicate, payload USING PARAMETERS expr = 'all', name = 'p2') OVER (PARTITION BY chunk_id) $IX;
               SELECT vbitmap.bm_member(1 USING PARAMETERS name = 'p2');")
if grep -q "call it OVER ()" <<< "$out" || { grep -q "Multiple values for the parameter pin_p2" <<< "$out" && grep -q "no set pinned as 'p2'" <<< "$out"; }; then
    pass "more than one partition pins nothing"
else
    fail "more than one partition pins nothing" "an error asking for OVER (), or WARNING 6870 and no set pinned" "$out"
fi
expect_error "input not restricted to one snapshot" "appears twice in chunk" \
  "SELECT vbitmap.bm_pin(chunk_id, predicate, payload USING PARAMETERS expr = 'all', name = 'a') OVER ()
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND domain = 'person';"
expect_error "corrupt payload" "invalid bitmap payload" \
  "SELECT vbitmap.bm_pin(chunk_id, SUBSTR(payload, 1, 20) USING PARAMETERS name = 'a') OVER () $IX AND predicate = 'all';"

finish_tests test_pinned

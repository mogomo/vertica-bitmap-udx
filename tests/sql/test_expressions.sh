#!/usr/bin/env bash
# Expression transforms on the fixture: expression forms of the queries, Q6 and Q7, scripts/bmq,
# random expressions against the native oracle, and the error cases.
#
#   tests/sql/test_expressions.sh [--keep]
#
# Runs after tests/sql/test_fixture.sh in run_all.sh and uses its schema bitmap_demo (it reloads
# the fixture itself if bitmap_demo is missing). Needs make deploy (library and build/bmexpr).
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh

if [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'bitmap_predicate';")" != 1 ]; then
    echo "== bitmap_demo missing: loading the fixture"
    tests/sql/test_fixture.sh > /dev/null || exit 1
fi

# bmq_sql MODE EXPR [options]: the SQL bmq runs, without its ORDER BY, for embedding.
bmq_sql() { local m="$1" e="$2"; shift 2; scripts/bmq --echo_only --mode="$m" "$@" "$e" | sed -e 's/ ORDER BY 1;$//' -e 's/;$//'; }

echo "== expression forms of the queries"
expect_query    "q1 expr count"  q1/expr_count 1 1 "3"
expect_query    "q1 expr ids"    q1/expr_ids   1 1 "1 65536 4294967296"
expect_same_set "q1 expr = native"       q1/native_ids q1/expr_ids 1 1
expect_same_set "q1 expr = native, t2"   q1/native_ids q1/expr_ids 2 1
expect_same_set "q1 expr = native, s9"   q1/native_ids q1/expr_ids 1 9
expect_query    "q3 expr"        q3/expr 1 1 "topic_finance|1 topic_sports|2"
expect_same_set "q3 expr = native"       q3/native q3/expr 1 1
expect_same_set "q3 disjunctive = native" q3/native_disjunctive q3/expr_disjunctive 1 1
expect_query    "q4 expr"        q4/expr 1 1 "10"
expect_query    "q5 expr"        q5/expr 1 1 "100"
expect_query    "q8 expr"        q8/expr 1 1 "1 2 7 4294967296"
expect_same_set "q8 expr = native"       q8/native q8/expr 1 1
expect_query    "q8 expr trap s1" q8/expr_trap 1 1 "6|6"
expect_query    "q8 expr trap s9" q8/expr_trap 1 9 "7|6"

expect_eq "bm_eval: stored result = bm_count, IDs = bm_ids" "3|1 65536 4294967296" \
  "SELECT (SELECT SUM(vbitmap.bm_cardinality(payload)) FROM (
             SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr = '$(echo 'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')')
                    OVER (PARTITION BY chunk_id)
             FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') e)
          || '|' || (SELECT LISTAGG(entity_id::VARCHAR USING PARAMETERS separator = ' ') WITHIN GROUP (ORDER BY entity_id) FROM (
             SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) FROM (
               SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr = 'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
                      OVER (PARTITION BY chunk_id)
               FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') e) i);"

echo "== Q6 retention grid, Q7 overlap ranking"
expect_query    "q6 native" q6/native 1 1 "2026-11-01 2026-11-01|2 2026-11-01 2026-11-02|1 2026-11-02 2026-11-02|2"
expect_query    "q6 bitmap" q6/bitmap 1 1 "2026-11-01 2026-11-01|2 2026-11-01 2026-11-02|1 2026-11-02 2026-11-02|2"
expect_same_set "q6 same set" q6/native q6/bitmap 1 1
expect_query    "q7 native" q7/native 1 1 "topic_finance|1|7|0.1429"
expect_query    "q7 bitmap" q7/bitmap 1 1 "topic_finance|1|7|0.1429"

echo "== bmq"
Q1='country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)'
out=$(scripts/bmq "$Q1" 2>&1);                         [ "$out" = 3 ] && pass "bmq count" || fail "bmq count" 3 "$out"
out=$(scripts/bmq --mode=ids "$Q1" 2>&1 | tr '\n' ' ');  [ "$out" = "1 65536 4294967296 " ] && pass "bmq ids" || fail "bmq ids" "1 65536 4294967296" "$out"
out=$(scripts/bmq --mode=native-count "$Q1" 2>&1);      [ "$out" = 3 ] && pass "bmq native count" || fail "bmq native count" 3 "$out"
out=$(scripts/bmq --mode=facets --facets=topic_ "$Q1" 2>&1 | tr '\n' ' ')
[ "$out" = "topic_sports|2 topic_finance|1 " ] && pass "bmq facets" || fail "bmq facets" "topic_sports|2 topic_finance|1" "$out"
out=$(scripts/bmq --mode=ids --max-ids=1 "all" 2>&1 | tr '\n' ' ')
[ "$out" = "1 65536 4294967296 " ] && pass "bmq max_ids (per chunk)" || fail "bmq max_ids (per chunk)" "1 65536 4294967296" "$out"
out=$(scripts/bmq "country_IL & topic_chess" 2>&1)
[ "$out" = 0 ] && pass "bmq: a name of a certified family without payload is empty" || fail "bmq: certified family, no payload" 0 "$out"
out=$(scripts/bmq "consent_false | country_US" 2>&1)
[ "$out" = 1 ] && pass "bmq: consent_false (certified, never built) | country_US" || fail "bmq: consent_false | country_US" 1 "$out"
expect_cmd "bmq refuses a name of no family" fail "cuontry_IL: matches no predicate family of domain person" scripts/bmq "cuontry_IL & all"
expect_cmd "bmq refuses an unpublished snapshot through the views" fail "no published snapshot 9" scripts/bmq --snapshot=9 all
expect_cmd "bmq --raw reads an unpublished snapshot (8 people)" ok "^8$" scripts/bmq --raw --snapshot=9 all
# The bmq oracle reads the same catalog as the builder: check both against hand-written SQL too.
want=$(run_sql "SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id = 1 AND age IS NOT NULL;")
out="$(scripts/bmq age_known 2>&1) $(scripts/bmq --mode=native-count age_known 2>&1)"
[ "$out" = "$want $want" ] && pass "age_known (second branch of a multi-line definition) = hand-written SQL" || fail "age_known = hand-written SQL" "$want $want" "$out"
out=$(scripts/bmq "a & (b" 2>&1)
echo "$out" | grep -q "misses a ')' at position 7" && pass "bmq syntax error" || fail "bmq syntax error" "misses a ')'" "$out"

echo "== random expressions: bm_ids = native SQL (seeded)"
NAMES=(country_IL country_US age_25_54 age_known consent_true suspended_true suspended_false topic_sports topic_finance all)
OPS=('&' '|' '-' '^')
RANDOM=20261112
gen() {   # gen DEPTH
    if [ "$1" -le 0 ] || [ $((RANDOM % 3)) -eq 0 ]; then echo -n "${NAMES[$((RANDOM % ${#NAMES[@]}))]}"; return; fi
    echo -n "($(gen $(($1 - 1))) ${OPS[$((RANDOM % 4))]} $(gen $(($1 - 1))))"
}
bad=0; nonempty=0
for snap in 1 9; do
    for i in $(seq 1 20); do
        e=$(gen 4)
        # snapshot 1 through the reader views, snapshot 9 (verified, not published) from the tables
        opt=--snapshot=$snap; [ "$snap" = 9 ] && opt="--snapshot=9 --raw"
        # shellcheck disable=SC2086
        a=$(bmq_sql ids "$e" $opt); b=$(bmq_sql native-ids "$e" $opt)
        d="$(run_sql "$(set_diff_sql "$a" "$b")") $(run_sql "$(set_diff_sql "$b" "$a")")"
        n=$(run_sql "SELECT COUNT(*) FROM ($b) n;")
        [ "$n" != 0 ] && nonempty=$((nonempty + 1))
        if [ "$d" != "0 0" ]; then bad=$((bad + 1)); echo "      differs (snapshot $snap): $e -> $d"; fi
    done
done
[ "$bad" = 0 ] && pass "40 random expressions agree with native SQL ($nonempty non-empty)" || fail "random expressions" "0 differences" "$bad differences"

echo "== bm_ids_text: the ID list as text blocks"
expect_eq "bm_ids_text lines = bm_ids rows" "1 4294967296 65536" \
  "SELECT vbitmap.bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr = '$Q1') OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person' ORDER BY 1;"
expect_eq "bm_ids_text: one block per chunk, separator inside a block only" "4294967296 1,2,3,4,7 65536" \
  "SELECT ids FROM (SELECT vbitmap.bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr = 'all', sep = ',') OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') t ORDER BY LENGTH(ids) DESC, ids;"
expect_eq "bm_ids text = true: the same IDs, one decimal string per row" "1|1 65536|5 4294967296|10" \
  "SELECT entity_id, LENGTH(entity_id) FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = '$Q1', text = true) OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') t ORDER BY entity_id::INT;"
expect_eq "bm_ids text = true with max_ids; text = false is the INT form" "1,2,65536,4294967296|14" \
  "SELECT (SELECT LISTAGG(entity_id) WITHIN GROUP (ORDER BY entity_id::INT) FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = 'all', max_ids = 2, text = true) OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') t),
          (SELECT SUM(entity_id) FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = 'all - country_US', max_ids = 4, text = false) OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person' AND chunk_id = 0) t);"
expect_error "bm_ids_text: empty separator" "sep must not be empty" \
  "SELECT vbitmap.bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr = 'all', sep = '') OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person';"

echo "== bm_pair_count: facets as independent rows (PARTITION BEST)"
PAIR="SELECT vbitmap.bm_pair_count(f.predicate, a.payload, f.payload) OVER (PARTITION BEST)
      FROM bitmap_demo.bitmap_index f
      JOIN (SELECT chunk_id, payload FROM (SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr = '$Q1') OVER (PARTITION BY chunk_id)
            FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') e) a ON a.chunk_id = f.chunk_id
      WHERE f.tenant_id = 1 AND f.snapshot_id = 1 AND f.domain = 'person' AND f.predicate LIKE 'topic\\_%'"
expect_eq "pair counts = q3 facets" "topic_finance|1 topic_sports|2" \
  "SELECT name, SUM(cnt) FROM ($PAIR) t GROUP BY name ORDER BY 1;"
expect_eq "pair counts = bm_facets on every snapshot row" "0" \
  "SELECT COUNT(*) FROM (
     (SELECT name, SUM(cnt) FROM ($PAIR) t GROUP BY name)
     EXCEPT
     (SELECT predicate, SUM(cnt) FROM (SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS expr = '$Q1', facets = 'topic_') OVER (PARTITION BY chunk_id)
        FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') u GROUP BY predicate)) d;"
expect_eq "pair with an empty or NULL side gives no row" "0" \
  "SELECT COUNT(*) FROM (SELECT vbitmap.bm_pair_count(predicate, payload, vbitmap.bm_empty()) OVER (PARTITION BEST)
     FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person'
   UNION ALL SELECT vbitmap.bm_pair_count(predicate, payload, NULL::VARBINARY(16384)) OVER (PARTITION BEST)
     FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') t;"

echo "== errors"
long="all$(printf '%*s' 64996 '')"   # 64,999 characters
expect_error "expression of 65,000 characters (may have been cut)" "the limit is 64999" \
  "SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = '$long ') OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person';"
expect_eq "expression of 64,999 characters is accepted" "7" \
  "SELECT SUM(cnt) FROM (SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = '$long') OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') t;"
expect_error "missing expr parameter" "parameter 'expr' is required" \
  "SELECT vbitmap.bm_count(chunk_id, predicate, payload) OVER (PARTITION BY chunk_id) FROM bitmap_demo.bitmap_index;"
expect_error "syntax error reported with position" "unexpected '!' where an operand is expected at position 1" \
  "SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = '!all') OVER (PARTITION BY chunk_id) FROM bitmap_demo.bitmap_index;"
expect_error "input not restricted to one snapshot" "appears twice in chunk" \
  "SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'all') OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND domain = 'person';"
expect_error "partition is not the chunk" "use OVER \\(PARTITION BY chunk_id\\)" \
  "SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'all') OVER ()
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person';"
expect_error "exclude removes every operand" "no operand left after excluding" \
  "SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_a | topic_b', facets = 'topic_', exclude = 'topic_')
   OVER (PARTITION BY chunk_id) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person';"
expect_error "corrupt payload" "invalid bitmap payload" \
  "SELECT vbitmap.bm_count(chunk_id, predicate, SUBSTR(payload, 1, 20) USING PARAMETERS expr = 'all') OVER (PARTITION BY chunk_id)
   FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person';"

finish_tests test_expressions

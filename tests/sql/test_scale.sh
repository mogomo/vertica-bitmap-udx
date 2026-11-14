#!/usr/bin/env bash
# Agreement at scale: generated people (tenant 3), the person index built and published through
# the lifecycle, and the native, explicit-bitmap and expression paths compared server-side, as sets
# in both directions; then an incremental build (one touched range of users plus ordered add /
# remove changes spread over every chunk) compared byte for byte with a full build.
#
#   tests/sql/test_scale.sh [--users=1000000] [--expressions=30] [--regenerate]
#
# Generates the data and builds snapshot 1 when tenant 3 source snapshot 1 does not have --users
# people (or with --regenerate). Not part of run_all.sh: it needs a few minutes per million users.
# Single runs are timed for orientation only; measurements are made by the benchmark (M5).
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh

USERS=1000000; NEXPR=30; REGEN=no
for arg in "$@"; do
    case "$arg" in
        --users=*)       USERS="${arg#*=}" ;;
        --expressions=*) NEXPR="${arg#*=}" ;;
        --regenerate)    REGEN=yes ;;
        -h|--help)       sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "test_scale.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
T=3; S=1
WM='2026-11-03 00:00:00'
SNAP=scripts/snapshot.sh

if [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'bitmap_reader';")" != 1 ]; then
    tests/sql/test_fixture.sh > /dev/null || exit 1
fi
# drop_tenant_index: every snapshot, change and index row of tenant 3 (test data only).
drop_tenant_index() {
    run_sql "DELETE FROM bitmap_demo.bitmap_index WHERE tenant_id = $T; DELETE FROM bitmap_demo.bitmap_predicate WHERE tenant_id = $T;
             DELETE FROM bitmap_demo.daily_bitmap WHERE tenant_id = $T; DELETE FROM bitmap_demo.bitmap_membership WHERE tenant_id = $T;
             DELETE FROM bitmap_demo.bitmap_change WHERE tenant_id = $T; DELETE FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $T;
             DELETE FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id <> $S;
             DELETE FROM bitmap_demo.user_interest WHERE tenant_id = $T AND snapshot_id <> $S; COMMIT;" > /dev/null
}
have=$(run_sql "SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S;")
if [ "$REGEN" = yes ] || [ "$have" != "$USERS" ]; then
    echo "== generate $USERS people"
    drop_tenant_index
    scripts/generate.sh --tenant=$T --snapshot=$S --users="$USERS" --replace || exit 1
fi
run_sql "INSERT INTO bitmap_demo.bitmap_reader SELECT CURRENT_USER(), $T FROM (SELECT 1 AS x) o
         WHERE NOT EXISTS (SELECT 1 FROM bitmap_demo.bitmap_reader WHERE user_name = CURRENT_USER() AND tenant_id = $T); COMMIT;" > /dev/null
if [ "$(run_sql "SELECT COUNT(*) FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $T AND domain = 'person' AND snapshot_id = $S AND state = 'active';")" != 1 ]; then
    echo "== build, validate and publish person snapshot $S"
    drop_tenant_index
    $SNAP build --tenant=$T --domain=person --snapshot=$S --watermark="$WM" --publish || exit 1
fi

# timed NAME SQL: runs SQL, prints "NAME: result (seconds)".
timed() {
    local t0 out
    t0=$(date +%s.%N)
    out=$(run_sql "$2")
    printf '      %-28s %s  (%.3f s, single run)\n' "$1" "$out" "$(echo "$(date +%s.%N) - $t0" | bc)"
    echo "$out"
}

Q1='country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)'
echo "== Q1 on $USERS people: three paths"
n=$(timed "native count"   "$(query_sql q1/native_count $T $S);" | tee /dev/stderr | tail -n 1)
b=$(timed "explicit bitmap" "$(query_sql q1/bitmap_count $T $S);" | tee /dev/stderr | tail -n 1)
e=$(timed "expression"      "$(query_sql q1/expr_count $T $S);" | tee /dev/stderr | tail -n 1)
[ "$n" = "$b" ] && [ "$n" = "$e" ] && [ "$n" -gt 0 ] && pass "q1 counts agree ($n)" || fail "q1 counts agree" "$n $n $n" "$n $b $e"
expect_same_set "q1 ids: native = expression"      q1/native_ids q1/expr_ids   $T $S
expect_same_set "q1 ids: native = explicit bitmap" q1/native_ids q1/bitmap_ids $T $S
expect_same_set "q3 facets: native = facet transform" q3/native q3/expr $T $S
expect_same_set "q3 facets: native = explicit bitmap" q3/native q3/bitmap $T $S
expect_same_set "q3 disjunctive facets"             q3/native_disjunctive q3/expr_disjunctive $T $S
expect_same_set "q8: native = expression"           q8/native q8/expr $T $S
expect_eq       "q8 trap: native = expression" "$(run_sql "$(query_sql q8/native_trap $T $S);")" "$(query_sql q8/expr_trap $T $S);"

echo "== $NEXPR random expressions over countries, topics, age, consent, suspension (seeded)"
mapfile -t NAMES < <(run_sql "SELECT predicate FROM bitmap_demo.bitmap_predicate WHERE tenant_id = $T AND snapshot_id = $S
                              AND (family <> 'country' OR predicate IN ('country_IL', 'country_US', 'country_DE', 'country_AU'))
                              AND (family <> 'topic' OR predicate < 'topic_t120' OR predicate IN ('topic_sports', 'topic_finance'))
                              ORDER BY 1;" | tr ' ' '\n')
OPS=('&' '|' '-' '^' '&' '&')
RANDOM=42
gen() {
    if [ "$1" -le 0 ] || [ $((RANDOM % 3)) -eq 0 ]; then echo -n "${NAMES[$((RANDOM % ${#NAMES[@]}))]}"; return; fi
    echo -n "($(gen $(($1 - 1))) ${OPS[$((RANDOM % ${#OPS[@]}))]} $(gen $(($1 - 1))))"
}
bad=0; sizes=""
for i in $(seq 1 "$NEXPR"); do
    ex=$(gen 4)
    a=$(scripts/bmq --echo_only --mode=ids --tenant=$T --snapshot=$S "$ex" | sed 's/ ORDER BY 1;$//')
    nat=$(scripts/bmq --echo_only --mode=native-ids --tenant=$T --snapshot=$S "$ex" | sed 's/ ORDER BY 1;$//')
    d="$(run_sql "$(set_diff_sql "$a" "$nat")") $(run_sql "$(set_diff_sql "$nat" "$a")")"
    c1=$(scripts/bmq --tenant=$T --snapshot=$S "$ex" 2>&1)
    c2=$(run_sql "SELECT COUNT(*) FROM ($nat) q;")
    sizes+=" $c2"
    if [ "$d" != "0 0" ] || [ "$c1" != "$c2" ]; then bad=$((bad + 1)); echo "      differs: $ex -> diff $d, count $c1 vs $c2"; fi
done
[ "$bad" = 0 ] && pass "$NEXPR random expressions agree with native SQL (sizes:$sizes)" || fail "random expressions" "0 differences" "$bad"

echo "== plan of the expression transform (index table and reader views)"
for src in "$(query_sql q1/expr_count $T $S)" "$(scripts/bmq --echo_only --tenant=$T "$Q1" | sed 's/;$//')"; do
    plan=$(run_sql "EXPLAIN $src;")
    if echo "$plan" | grep -q -i "broadcast"; then fail "no broadcast" "none" "$(echo "$plan" | grep -i -o '.\{40\}broadcast.\{20\}' | head -n 1)"; else pass "no broadcast"; fi
    global=$(echo "$plan" | grep -o -i '[a-z]* resegment' | grep -v -i -E 'local resegment|locally resegment' || true)
    [ -z "$global" ] && pass "no resegmentation between nodes (only local)" || fail "no resegmentation between nodes" "only local" "$global"
done

echo "== incremental build: users 100000..109999 touched, ordered add / remove of topic_chess over every chunk"
cleanup_inc() {
    for s2 in 2 3; do $SNAP discard --tenant=$T --domain=person --snapshot=$s2 > /dev/null 2>&1 || true; done
    run_sql "DELETE FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = 2;
             DELETE FROM bitmap_demo.user_interest WHERE tenant_id = $T AND snapshot_id = 2;
             DELETE FROM bitmap_demo.bitmap_change WHERE tenant_id = $T; COMMIT;" > /dev/null
}
cleanup_inc
# Source snapshot 2: the touched users flip consent and lose sports; every user with ID % 100 = 7
# gains chess. The change batch reports the same, with ordered noise: % 1000 = 7 are added,
# removed and added again; % 100 = 8 are added and removed.
run_sql "INSERT /*+DIRECT*/ INTO bitmap_demo.user_profile
           SELECT tenant_id, 2, entity_id, country, age,
                  CASE WHEN entity_id >= 100000 AND entity_id < 110000 THEN NOT consent ELSE consent END, suspended
           FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S;
         INSERT /*+DIRECT*/ INTO bitmap_demo.user_interest
           SELECT tenant_id, 2, entity_id, topic FROM bitmap_demo.user_interest WHERE tenant_id = $T AND snapshot_id = $S
             AND NOT (entity_id >= 100000 AND entity_id < 110000 AND topic = 'sports')
           UNION ALL SELECT $T, 2, entity_id, 'chess' FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S AND entity_id % 100 = 7;
         INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_change (tenant_id, domain, batch_id, seq, op, predicate, entity_id)
           SELECT $T, 'person', 1, ROW_NUMBER() OVER (ORDER BY ord, entity_id), op, predicate, entity_id FROM (
             SELECT 1 AS ord, 'touch' AS op, NULL AS predicate, entity_id FROM bitmap_demo.user_profile
               WHERE tenant_id = $T AND snapshot_id = $S AND entity_id >= 100000 AND entity_id < 110000
             UNION ALL SELECT 2, 'add', 'topic_chess', entity_id FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S AND entity_id % 100 = 7
             UNION ALL SELECT 3, 'remove', 'topic_chess', entity_id FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S AND entity_id % 1000 = 7
             UNION ALL SELECT 4, 'add', 'topic_chess', entity_id FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S AND entity_id % 1000 = 7
             UNION ALL SELECT 5, 'add', 'topic_chess', entity_id FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S AND entity_id % 100 = 8
             UNION ALL SELECT 6, 'remove', 'topic_chess', entity_id FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S AND entity_id % 100 = 8) c;
         COMMIT;" > /dev/null
t0=$(date +%s.%N)
expect_cmd "apply batch 1 (incremental snapshot 2, validated against source snapshot 2)" ok "verified" \
  $SNAP apply --tenant=$T --domain=person --batch=1 --source-snapshot=2 --snapshot=2
printf '      incremental build and validation: %.1f s (single run)\n' "$(echo "$(date +%s.%N) - $t0" | bc)"
t0=$(date +%s.%N)
expect_cmd "full build of the same state (snapshot 3)" ok "verified" \
  $SNAP build --tenant=$T --domain=person --snapshot=3 --source-snapshot=2 --batch=1 --watermark="$WM"
printf '      full build and validation: %.1f s (single run)\n' "$(echo "$(date +%s.%N) - $t0" | bc)"
i="SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = $T AND domain = 'person' AND snapshot_id"
expect_eq "incremental = full, byte for byte (both directions), topic_chess = users with ID % 100 = 7" "0 0 t" \
  "SELECT (SELECT COUNT(*) FROM ($i = 2 EXCEPT $i = 3) a) || ' ' || (SELECT COUNT(*) FROM ($i = 3 EXCEPT $i = 2) b) || ' ' ||
          ((SELECT SUM(cardinality) FROM bitmap_demo.bitmap_predicate WHERE tenant_id = $T AND snapshot_id = 2 AND predicate = 'topic_chess')
           = (SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE tenant_id = $T AND snapshot_id = $S AND entity_id % 100 = 7))::VARCHAR;"
cleanup_inc

finish_tests test_scale

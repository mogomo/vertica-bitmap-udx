# Shared by the tests in tests/sql. Sourced, not run; expects the repository root as working
# directory. Connection: vsql reads VSQL_HOST, VSQL_PORT, VSQL_USER, VSQL_PASSWORD, VSQL_DATABASE.

. scripts/lib_sql.sh

FAILED=0
PASSED=0

# run_sql SQL: unaligned output, one line per row, rows joined by spaces.
run_sql() { printf '%s\n' "$1" | vsql -X -A -t -q 2>&1 | tr '\n' ' ' | sed 's/ *$//'; }

# run_file FILE [vsql options]: runs a SQL file, stops at the first error.
run_file() { local f="$1"; shift; vsql -X -q -v ON_ERROR_STOP=1 "$@" -f "$f" > /dev/null; }

pass() { echo "PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL  $1"; echo "      wanted: $2"; echo "      got:    $3" | cut -c1-400; FAILED=$((FAILED + 1)); }

# expect_eq NAME EXPECTED SQL: the rows (sorted by the caller), joined by spaces, equal EXPECTED.
expect_eq() {
    local out
    out=$(run_sql "$3")
    if [ "$out" = "$2" ]; then pass "$1"; else fail "$1" "$2" "$out"; fi
}

# expect_error NAME PATTERN SQL: the statement fails with an error matching PATTERN (grep -E).
expect_error() {
    local out
    out=$(run_sql "$3")
    if echo "$out" | grep -q "ERROR" && echo "$out" | grep -q -E -- "$2"; then pass "$1"; else fail "$1" "ERROR ~ $2" "$out"; fi
}

# expect_query NAME QUERY TENANT SNAPSHOT EXPECTED [WATERMARK]: rows of sql/queries/QUERY sorted
# by the first column (unique in every query result), equal EXPECTED.
expect_query() {
    expect_eq "$1" "$5" "SELECT * FROM ($(query_sql "$2" "$3" "$4" "${6:-}")) q ORDER BY 1;"
}

# set_diff_sql A B: SQL counting the rows of A that are not in B. Each operand is wrapped in
# SELECT * FROM (...), so that a query whose select list is a transform function (bm_to_ids) is
# never a direct operand of EXCEPT.
set_diff_sql() { echo "SELECT COUNT(*) FROM ((SELECT * FROM ($1) a) EXCEPT (SELECT * FROM ($2) b)) d;"; }

# expect_same_set NAME QUERY_A QUERY_B TENANT SNAPSHOT [WATERMARK]: A EXCEPT B and B EXCEPT A are
# both empty, and A is not empty (so that the comparison is not vacuous).
expect_same_set() {
    local a b out
    a=$(query_sql "$2" "$4" "$5" "${6:-}")
    b=$(query_sql "$3" "$4" "$5" "${6:-}")
    out="$(run_sql "$(set_diff_sql "$a" "$b")") $(run_sql "$(set_diff_sql "$b" "$a")") $(run_sql "SELECT CASE WHEN COUNT(*) > 0 THEN 'nonempty' ELSE 'EMPTY' END FROM ($a) n;")"
    if [ "$out" = "0 0 nonempty" ]; then pass "$1"; else fail "$1" "0 0 nonempty" "$out"; fi
}

# expect_cmd NAME ok|fail PATTERN COMMAND...: the command succeeds (ok) or fails (fail) and its
# output (stdout and stderr) matches PATTERN (grep -E; empty: any output).
expect_cmd() {
    local name="$1" want="$2" pat="$3" out rc=0
    shift 3
    out=$("$@" 2>&1) || rc=$?
    if { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; then
        if [ -z "$pat" ] || grep -q -E -- "$pat" <<< "$out"; then pass "$name"; return 0; fi
    fi
    fail "$name" "$want ~ $pat" "exit $rc: $(tr '\n' ' ' <<< "$out")"
}

# Fixture watermarks: after the last event (person), the observation time of the devices, after
# the last refresh (asset).
FIX_WM_PERSON='2026-11-03 00:00:00'
FIX_WM_DEVICE='2026-11-01 12:00:00'
FIX_WM_ASSET='2026-11-01 00:00:00'

# setup_fixture: fresh schema bitmap_demo with the fixture, the catalog of tenants 1 and 2, the
# query role, the current user as reader of tenants 1 to 3, and published snapshot 1 of tenant 1
# (person with daily sets, device, asset) and tenant 2 (person, built via bitmap_membership).
setup_fixture() {
    local out
    run_file sql/drop_schema.sql
    run_file sql/schema.sql || return 1
    out=$(vsql -X -q -v ON_ERROR_STOP=1 -f sql/access.sql 2>&1 > /dev/null) || { echo "$out"; return 1; }
    grep -v -E 'User/role "bitmap_demo_query" already exists' <<< "$out" || true
    run_file sql/fixture.sql || return 1
    for t in 1 2; do run_file sql/families.sql -v tenant=$t || return 1; done
    run_sql "INSERT INTO bitmap_demo.bitmap_reader SELECT CURRENT_USER(), 1 UNION ALL SELECT CURRENT_USER(), 2
             UNION ALL SELECT CURRENT_USER(), 3; COMMIT;" > /dev/null
    out=$( { scripts/snapshot.sh build --tenant=1 --domain=person --snapshot=1 --watermark="$FIX_WM_PERSON" --daily --deep --publish &&
             scripts/snapshot.sh build --tenant=1 --domain=device --snapshot=1 --watermark="$FIX_WM_DEVICE" --deep --publish &&
             scripts/snapshot.sh build --tenant=1 --domain=asset  --snapshot=1 --watermark="$FIX_WM_ASSET" --deep --publish &&
             scripts/snapshot.sh build --tenant=2 --domain=person --snapshot=1 --watermark="$FIX_WM_PERSON" --via-membership --deep --publish; } 2>&1) \
        || { echo "$out"; return 1; }
}

# finish_tests NAME: summary line and exit code.
finish_tests() {
    if [ "$FAILED" -ne 0 ]; then echo "$1: $FAILED FAILED, $PASSED passed"; exit 1; fi
    echo "$1: OK ($PASSED passed)"
}

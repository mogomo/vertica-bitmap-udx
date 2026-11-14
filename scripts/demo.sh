#!/usr/bin/env bash
# Guided demo: exact audience analytics with the bitmap index, end to end, on one demo tenant.
#
#   scripts/demo.sh [--tenant=100] [--size=small|default] [--pause] [--keep]
#
#   --size=small    1 M people, 20 M interests, 10 M events (about 2 minutes to set up; default)
#   --size=default  10 M people, 200 M interests, 100 M events (the benchmark's size)
#   --pause         wait for Enter between the steps (for a live presentation)
#   --keep          leave the demo tenant in place at the end (default: its rows are deleted)
#
# Steps: (1) generate the tenant's data; (2) build, validate and publish the index snapshot;
# (3) the audience question in native SQL and through the index: same answer; (4) change the
# question: every variant costs about the same; (5) facets: the audience per topic; (6) the IDs;
# (7) fresh data: apply a 1 % change batch, validate, publish; (8) roll back in one statement.
# Needs: the functions deployed (make deploy), build/bmexpr (make tools), schema bitmap_demo
# (created here from sql/schema.sql and sql/access.sql if it does not exist). Never drops the schema
# and touches no other tenant. Connection: the VSQL_* environment variables.
set -euo pipefail

cd "$(dirname "$0")/.."
TENANT=100; SIZE=small; PAUSE=no; KEEP=no
for arg in "$@"; do
    case "$arg" in
        --tenant=*) TENANT="${arg#*=}" ;;
        --size=*)   SIZE="${arg#*=}" ;;
        --pause)    PAUSE=yes ;;
        --keep)     KEEP=yes ;;
        -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "demo.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[[ "$TENANT" =~ ^[0-9]+$ ]] || { echo "demo.sh: --tenant must be a number" >&2; exit 2; }
case "$SIZE" in small|default) ;; *) echo "demo.sh: --size is small or default" >&2; exit 2 ;; esac

VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { printf '%s\n' "$1" | "${VSQL[@]}"; }
now() { date +%s.%N; }
secs() { printf '%.2f s' "$(echo "$(now) - $1" | bc)"; }
step() { echo; echo "== $*"; [ "$PAUSE" = no ] || read -r -p "   (Enter) " _; }
show() { echo "   \$ $*"; }
W="2026-11-01 00:00:00"
AUDIENCE='country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)'

if [ "$(q "SELECT COUNT(*) FROM v_catalog.schemata WHERE schema_name = 'bitmap_demo'")" = 0 ]; then
    echo "Creating schema bitmap_demo (sql/schema.sql, sql/access.sql)"
    "${VSQL[@]}" -f sql/schema.sql > /dev/null
    "${VSQL[@]}" -f sql/access.sql > /dev/null
fi
[ "$(q "SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT")" = 0 ] \
    || { echo "demo.sh: tenant $TENANT already has data; choose another --tenant" >&2; exit 1; }
q "INSERT INTO bitmap_demo.bitmap_reader SELECT CURRENT_USER(), $TENANT
   WHERE NOT EXISTS (SELECT 1 FROM bitmap_demo.bitmap_reader WHERE user_name = CURRENT_USER() AND tenant_id = $TENANT); COMMIT;" > /dev/null

cleanup() {
    [ "$KEEP" = yes ] && { echo; echo "Demo tenant $TENANT kept."; return 0; }
    echo; echo "Removing demo tenant $TENANT"
    local t
    for t in bitmap_index bitmap_predicate daily_bitmap bitmap_snapshot bitmap_change bitmap_family \
             user_profile user_interest event_log device_state asset_state asset_source gen_person; do
        q "DELETE FROM bitmap_demo.$t WHERE tenant_id = $TENANT; COMMIT;" > /dev/null || true
    done
    q "DELETE FROM bitmap_demo.bitmap_reader WHERE tenant_id = $TENANT; COMMIT;" > /dev/null || true
}
trap cleanup EXIT

step "1. Data: $SIZE preset for tenant $TENANT (people, interests, events, devices, assets)"
show scripts/generate.sh --tenant=$TENANT --snapshot=1 --$SIZE --topic-skew=1.5
t0=$(now)
scripts/generate.sh --tenant="$TENANT" --snapshot=1 --"$SIZE" --topic-skew=1.5 | tail -n 1 | tr ' ' '\n' | grep -E '^(people|interests|events)=' | sed 's/^/   /'
echo "   ($(secs "$t0"))"

step "2. Build the index snapshot, validate it against the source, publish it"
show scripts/snapshot.sh build --tenant=$TENANT --domain=person --snapshot=1 --watermark="'$W'" --daily --publish
scripts/snapshot.sh build --tenant="$TENANT" --domain=person --snapshot=1 --watermark="$W" --daily --publish \
    | grep -E '^  (ok|FAIL)|^snapshot: ' | sed -E 's/^snapshot: (.*)/   result: \1/'

step "3. The audience question: IL, 25-54, consent, not suspended, likes sports or finance"
echo "   Native SQL over the source tables (INTERSECT / UNION of the family definitions):"
show scripts/bmq --tenant=$TENANT --mode=native-count "'$AUDIENCE'"
t0=$(now); n=$(scripts/bmq --tenant="$TENANT" --mode=native-count "$AUDIENCE"); echo "   $n people   ($(secs "$t0"))"
echo "   The bitmap index (one pass per ID chunk):"
show scripts/bmq --tenant=$TENANT "'$AUDIENCE'"
t0=$(now); b=$(scripts/bmq --tenant="$TENANT" "$AUDIENCE"); echo "   $b people   ($(secs "$t0"))"
[ "$n" = "$b" ] && echo "   same answer" || { echo "   ANSWERS DIFFER"; exit 1; }

step "4. Change the question: every variant costs about the same"
for e in 'country_IL & topic_sports' 'country_IL & topic_sports - topic_finance' \
         '(country_US | country_DE) & age_25_54 & consent_true & topic_t42' \
         "$AUDIENCE - topic_t7"; do
    t0=$(now); c=$(scripts/bmq --tenant="$TENANT" "$e"); printf '   %-70s %10s   (%s)\n' "$e" "$c" "$(secs "$t0")"
done

step "5. Facets: the audience per topic (top 10 of 500), one pass"
show scripts/bmq --tenant=$TENANT --mode=facets --facets=topic_ "'$AUDIENCE'"
t0=$(now)
# awk reads its whole input: with "head" the writer would be ended by SIGPIPE and, under pipefail, the demo with it
scripts/bmq --tenant="$TENANT" --mode=facets --facets=topic_ "$AUDIENCE" | sort -t'|' -k2 -n -r | awk 'NR <= 10 {print "   " $0}'
echo "   ($(secs "$t0") for all 500 topics)"

step "6. The IDs of the audience (first 5)"
show scripts/bmq --tenant=$TENANT --mode=ids "'$AUDIENCE'"
scripts/bmq --tenant="$TENANT" --mode=ids "$AUDIENCE" | awk 'NR <= 5 {print "   " $0} END {print "   ... (" NR " IDs)"}'

step "7. Fresh data: 1 % of the people change; apply the change batch, validate, publish"
show bench/refresh.sh --tenant=$TENANT --fraction=0.01 --report=delta --steps=apply --keep
bench/refresh.sh --tenant="$TENANT" --fraction=0.01 --report=delta --steps=apply --keep \
    | grep -E 'step=(changes|done)' | sed 's/^refresh: /   /'
s2=$(q "SELECT MAX(snapshot_id) FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $TENANT AND domain = 'person' AND state = 'verified'")
show scripts/snapshot.sh publish --tenant=$TENANT --domain=person --snapshot=$s2
scripts/snapshot.sh publish --tenant="$TENANT" --domain=person --snapshot="$s2" | sed 's/^/   /'
echo "   audience now: $(scripts/bmq --tenant="$TENANT" "$AUDIENCE") people (snapshot $s2; readers of snapshot 1 were never disturbed)"

step "8. Roll back: publish snapshot 1 again (one transaction)"
show scripts/snapshot.sh publish --tenant=$TENANT --domain=person --snapshot=1
scripts/snapshot.sh publish --tenant="$TENANT" --domain=person --snapshot=1 | sed 's/^/   /'
echo "   audience now: $(scripts/bmq --tenant="$TENANT" "$AUDIENCE") people (snapshot 1)"
scripts/snapshot.sh status --tenant="$TENANT" | sed 's/^/   /'

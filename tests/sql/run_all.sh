#!/usr/bin/env bash
# Runs every SQL test in each deploy mode, then deploys fenced again.
#
#   tests/sql/run_all.sh [--modes=yes,no]
#
# yes = fenced (run first: a fault there stops a side process), no = unfenced. The modes change
# where the functions run, not what they compute. Needs build/libvbitmap.so (make).
# Drops and recreates schemas bitmap_demo, bitmap_live and bitmap_test; creates and drops role
# bitmap_demo_query grants and the test user of test_lifecycle.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."

MODES=yes,no
for arg in "$@"; do
    case "$arg" in
        --modes=*) MODES="${arg#--modes=}" ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "run_all.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

status=0
for mode in ${MODES//,/ }; do
    echo "######## FENCED=$mode"
    scripts/deploy.sh --fenced="$mode" || { status=1; break; }
    for t in tests/sql/test_fixture.sh tests/sql/test_expressions.sh tests/sql/test_semantics.sh tests/sql/test_live.sh tests/sql/test_bitsliced.sh tests/sql/test_pinned.sh tests/sql/test_aggregate.sh tests/sql/test_lifecycle.sh; do
        "$t" || status=1
    done
    [ "$status" -eq 0 ] || break
done
scripts/deploy.sh --fenced=yes > /dev/null
[ "$status" -eq 0 ] && echo "run_all: all SQL tests passed in modes $MODES" || echo "run_all: FAILED"
exit "$status"

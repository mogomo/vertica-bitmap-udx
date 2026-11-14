#!/usr/bin/env bash
# Installs or removes the vbitmap library and functions (schema vbitmap).
#
#   scripts/deploy.sh [--fenced=yes|no] [--undeploy] [--echo_only]
#
#   --fenced=yes   every function runs in a separate fenced process (default; a fault in the
#                  library cannot stop the node)
#   --fenced=no    every function runs inside the Vertica process (no data transfer to a side
#                  process; a fault in the library is a fault of the node)
#   --undeploy     remove the library, its functions and schema vbitmap
#   --echo_only    print the vsql command instead of running it
#
# Connection: vsql reads VSQL_HOST, VSQL_PORT, VSQL_USER, VSQL_PASSWORD and VSQL_DATABASE from
# the environment. Run on a Vertica node: CREATE LIBRARY reads the .so from the initiator node.
set -euo pipefail

cd "$(dirname "$0")/.."

FENCED=yes
UNDEPLOY=no
ECHO_ONLY=no
for arg in "$@"; do
    case "$arg" in
        --fenced=yes|--fenced=no) FENCED="${arg#--fenced=}" ;;
        --undeploy)  UNDEPLOY=yes ;;
        --echo_only) ECHO_ONLY=yes ;;
        -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "deploy.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

LIBFILE="$PWD/build/libvbitmap.so"
FENCED_SQL="FENCED"
[ "$FENCED" = no ] && FENCED_SQL="NOT FENCED"

if [ "$UNDEPLOY" = yes ]; then
    CMD=(vsql -X -v ON_ERROR_STOP=1 -f sql/uninstall.sql)
else
    CMD=(vsql -X -v ON_ERROR_STOP=1 -v "libfile='$LIBFILE'" -v "fenced=$FENCED_SQL" -f sql/install.sql)
fi

if [ "$ECHO_ONLY" = yes ]; then
    printf '%q ' "${CMD[@]}"; echo
    exit 0
fi

if [ "$UNDEPLOY" = no ] && [ ! -f "$LIBFILE" ]; then
    echo "deploy.sh: $LIBFILE not found. Run make first." >&2
    exit 1
fi

rc=0
err=$("${CMD[@]}" 2>&1 > /dev/null) || rc=$?
err=$(printf '%s\n' "$err" | grep -v 'NOTICE 4214' || true)   # "schema already exists"
[ -n "$err" ] && printf '%s\n' "$err" >&2
[ "$rc" -eq 0 ] || exit "$rc"

# The aggregate functions exist in an unfenced deployment only (Vertica cannot fence aggregates).
if [ "$UNDEPLOY" = no ]; then
    AGG=sql/drop_aggregates.sql
    [ "$FENCED" = no ] && AGG=sql/install_aggregates.sql
    err=$(vsql -X -v ON_ERROR_STOP=1 -f "$AGG" 2>&1 > /dev/null) || rc=$?
    err=$(printf '%s\n' "$err" | grep -v 'NOTICE 4185\|NOTICE 3185\|does not exist' || true)   # nothing to drop
    [ -n "$err" ] && printf '%s\n' "$err" >&2
    [ "$rc" -eq 0 ] || exit "$rc"
fi

if [ "$UNDEPLOY" = no ]; then
    vsql -X -A -t -c "SELECT vbitmap.bm_version();"
    vsql -X -A -t -c "SELECT COUNT(*) || ' functions, fenced: ' || MIN(is_fenced::VARCHAR) || '..' || MAX(is_fenced::VARCHAR)
                      FROM v_catalog.user_functions WHERE schema_name = 'vbitmap';"
else
    echo "vbitmap removed."
fi

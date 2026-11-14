#!/usr/bin/env bash
# Runs one query of sql/queries with its rows sorted.
#
#   scripts/run_query.sh NAME [--tenant=1] [--snapshot=1] [--watermark=TS] [--echo_only]
#
#   NAME   e.g. q1/native_ids, q1/bitmap_ids, q3/bitmap (see sql/queries/README.md)
#   --watermark  value of ${watermark} (q4/native: the device snapshot's watermark)
#
# Connection: vsql reads VSQL_HOST, VSQL_PORT, VSQL_USER, VSQL_PASSWORD and VSQL_DATABASE.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib_sql.sh

NAME=""; TENANT=1; SNAPSHOT=1; WM=""; ECHO_ONLY=no
for arg in "$@"; do
    case "$arg" in
        --tenant=*)   TENANT="${arg#*=}" ;;
        --snapshot=*) SNAPSHOT="${arg#*=}" ;;
        --watermark=*) WM="${arg#*=}" ;;
        --echo_only)  ECHO_ONLY=yes ;;
        -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
        -*) echo "run_query.sh: unknown argument: $arg" >&2; exit 2 ;;
        *)  NAME="$arg" ;;
    esac
done
[ -n "$NAME" ] || { sed -n '2,10p' "$0"; exit 2; }
[[ "$TENANT" =~ ^[0-9]+$ && "$SNAPSHOT" =~ ^[0-9]+$ ]] || { echo "run_query.sh: --tenant and --snapshot must be integers" >&2; exit 2; }

SQL="SELECT * FROM (
$(query_sql "$NAME" "$TENANT" "$SNAPSHOT" "$WM")
) q ORDER BY 1;"

if [ "$ECHO_ONLY" = yes ]; then printf '%s\n' "$SQL"; exit 0; fi
printf '%s\n' "$SQL" | vsql -X -v ON_ERROR_STOP=1

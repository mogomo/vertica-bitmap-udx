#!/usr/bin/env bash
# Storage of the project's tables: bytes on disk and rows per projection (Vertica).
#
#   bench/storage.sh [--schema=bitmap_demo]
#
# Reads v_monitor.projection_storage.
# Projection storage is per table, not per tenant: the line "tenants:" gives the rows per tenant
# of the source tables, so that a table holding several tenants can be read correctly.
# One line per projection: "storage: table=... projection=... rows=... used_bytes=...".
set -euo pipefail

SCHEMA=bitmap_demo
for arg in "$@"; do
    case "$arg" in
        --schema=*) SCHEMA="${arg#*=}" ;;
        -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "storage.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[[ "$SCHEMA" =~ ^[A-Za-z0-9_]+$ ]] || { echo "storage.sh: bad --schema" >&2; exit 2; }
VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { printf '%s\n' "$1" | "${VSQL[@]}"; }

q "SELECT 'storage: table=' || anchor_table_name || ' projection=' || projection_name || ' rows=' || SUM(row_count)
          || ' used_bytes=' || SUM(used_bytes) || ' ros_containers=' || SUM(ros_count)
   FROM v_monitor.projection_storage WHERE anchor_table_schema = '$SCHEMA'
   GROUP BY anchor_table_name, projection_name ORDER BY anchor_table_name, projection_name"
for t in user_profile user_interest event_log device_state asset_state asset_source bitmap_index daily_bitmap; do
    q "SELECT 'tenants: table=$t ' || LISTAGG(tenant_id || ':' || n USING PARAMETERS separator = ' ')
       FROM (SELECT tenant_id, COUNT(*) AS n FROM $SCHEMA.$t GROUP BY 1 ORDER BY 1) x"
done
q "SELECT 'summary: schema=$SCHEMA used_bytes=' || SUM(used_bytes) || ' rows=' || SUM(row_count)
   FROM v_monitor.projection_storage WHERE anchor_table_schema = '$SCHEMA'"

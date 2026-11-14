#!/usr/bin/env bash
# A bitmap index that Vertica keeps up to date by itself: live aggregate projections that call
# vbitmap.bm_build when rows are loaded and vbitmap.bm_union when containers are merged or read
# (sql/live.sql explains the mechanism and its limits).
#
#   scripts/live_index.sh create [--tables-only]     schema bitmap_live: tag and event tables and,
#                                                     unless --tables-only, the live projections
#   scripts/live_index.sh projections                 create the live projections over the rows
#                                                     already stored and refresh them
#   scripts/live_index.sh load --tenant=N [--source-snapshot=1] [--watermark=TS] [--domain=person]
#                                                     tag rows from the predicate catalog
#                                                     (bitmap_demo.bitmap_family) and the tenant's events
#   scripts/live_index.sh status                      projections, containers, rows, bytes
#   scripts/live_index.sh drop
#
# With the projections in place every INSERT or COPY into bitmap_live.tag or bitmap_live.event
# updates the sets in the same transaction. Read them as bitmap_live.bitmap_index (columns as
# bitmap_demo.bitmap_index) and bitmap_live.daily_bitmap (tenant_id, channel, day, chunk_id, payload):
#
#   SELECT SUM(cnt) FROM (
#     SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_sports - topic_finance')
#            OVER (PARTITION BY chunk_id)
#     FROM bitmap_live.bitmap_index
#     WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person'
#       AND predicate IN ('topic_sports', 'topic_finance')) t;
#
# Lines printed: "live: op=... key=value ...". Connection: the VSQL_* environment variables.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib_sql.sh

OP="${1:-}"; [ $# -gt 0 ] && shift
TENANT=""; SOURCE=1; WM=""; DOMAIN=person; TABLES_ONLY=no
for arg in "$@"; do
    case "$arg" in
        --tenant=*)          TENANT="${arg#*=}" ;;
        --source-snapshot=*) SOURCE="${arg#*=}" ;;
        --watermark=*)       WM="${arg#*=}" ;;
        --domain=*)          DOMAIN="${arg#*=}" ;;
        --tables-only)       TABLES_ONLY=yes ;;
        -h|--help)           sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "live_index.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
now() { date +%s.%N; }
elapsed() { printf '%.2f' "$(echo "$(now) - $1" | bc)"; }

projections() {
    local t0 t1
    t0=$(now)
    "${VSQL[@]}" -f sql/live_projections.sql 2>&1 | grep -v -e 'WARNING 9239' -e 'WARNING 4468' -e 'must have a sufficient number' || true
    t1=$(now)
    "${VSQL[@]}" -c "SELECT REFRESH('bitmap_live.tag, bitmap_live.event')" > /dev/null
    "${VSQL[@]}" -c "SELECT 'live: op=projections projection=' || projection_name || ' type=' || aggregate_type || ' up_to_date=' || is_up_to_date
                     FROM v_catalog.projections WHERE projection_schema = 'bitmap_live' AND aggregate_type <> '' ORDER BY 1"
    echo "live: op=projections create_s=$(printf '%.2f' "$(echo "$t1 - $t0" | bc)") refresh_s=$(elapsed "$t1")"
    if [ "$("${VSQL[@]}" -c "SELECT COUNT(*) FROM v_catalog.projections WHERE projection_schema = 'bitmap_live' AND aggregate_type <> '' AND NOT is_up_to_date")" != 0 ]; then
        echo "live_index.sh: a live projection could not be built from the stored rows (see vertica.log)" >&2
        return 1
    fi
}

status() {
    "${VSQL[@]}" -c "SELECT 'live: op=status projection=' || projection_name || ' containers=' || COUNT(*) || ' rows=' || SUM(total_row_count) || ' bytes=' || SUM(used_bytes)
                     FROM v_monitor.storage_containers WHERE schema_name = 'bitmap_live' GROUP BY projection_name ORDER BY 1"
}

case "$OP" in
create)
    "${VSQL[@]}" -f sql/live.sql
    if [ "$TABLES_ONLY" = no ]; then projections; else echo "live: op=create tables=tag,event projections=none"; fi ;;
projections) projections; status ;;
load)
    [[ "$TENANT" =~ ^[0-9]+$ && "$SOURCE" =~ ^[0-9]+$ ]] || { echo "live_index.sh: load needs --tenant=N" >&2; exit 2; }
    [[ "$DOMAIN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "live_index.sh: bad --domain" >&2; exit 2; }
    before="TRUE"
    if [ -n "$WM" ]; then ts_literal "$WM" > /dev/null || exit 2; before="event_ts < $(ts_literal "$WM")"; fi
    source_sql=$(family_union_sql "$TENANT" "$SOURCE" "$WM" "$DOMAIN") || exit 1
    t0=$(now)
    n=$(printf '%s\n' "INSERT /*+DIRECT*/ INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id)
SELECT $TENANT, $SOURCE, '$DOMAIN', predicate, entity_id FROM ($source_sql) s;" "COMMIT;" | "${VSQL[@]}" | sed -n 1p)
    echo "live: op=load table=tag tenant=$TENANT domain=$DOMAIN rows=$n s=$(elapsed "$t0")"
    t0=$(now)
    n=$(printf '%s\n' "INSERT /*+DIRECT*/ INTO bitmap_live.event (tenant_id, user_id, event_ts, channel)
SELECT tenant_id, user_id, event_ts, channel FROM bitmap_demo.event_log WHERE tenant_id = $TENANT AND $before;" "COMMIT;" | "${VSQL[@]}" | sed -n 1p)
    echo "live: op=load table=event tenant=$TENANT rows=$n s=$(elapsed "$t0")"
    status ;;
status) status ;;
drop)   "${VSQL[@]}" -f sql/drop_live.sql; echo "live: op=drop" ;;
*) sed -n '2,26p' "$0"; exit 2 ;;
esac

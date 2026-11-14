#!/usr/bin/env bash
# Database Designer comparison for the native path (plan section 17.2), on a copy schema.
#
#   bench/dbd.sh copy   --tenant=N [--schema=bitmap_dbd]
#   bench/dbd.sh design --queries=FILE --out=DIR [--schema=bitmap_dbd] [--design=vbitmap_dbd]
#   bench/dbd.sh drop   [--schema=bitmap_dbd] [--design=vbitmap_dbd]
#
# copy    creates the schema and copies the source tables of the native queries (user_profile,
#         user_interest, event_log, device_state, asset_state, asset_source) for one tenant, with the
#         same columns (CREATE TABLE ... LIKE, no projections copied: the first load makes Vertica's
#         default superprojection, so the designer starts from nothing hand-made), then statistics.
# design  a comprehensive design over every table of the schema, optimization objective QUERY,
#         the database's own K-safety (0 on the article's single node), the queries of FILE
#         (bench/make_dbd_workload.py --out-queries; it must be readable by the database
#         server), statistics analyzed, populated and deployed. DIR
#         receives design.sql and deploy.sql (written by the server), design_queries.txt (what the
#         designer accepted), projections.txt (deployment operations), projection_columns.txt (sort
#         order and encoding of every projection now on the copy) and storage.txt. The design
#         itself is dropped at the end; its projections stay on the copy.
# drop    drops the copy schema (and the design, if "design" was interrupted before it dropped it).
# Lines: "dbd: op=... key=value ...". Connection: the VSQL_* environment variables.
set -euo pipefail

OP="${1:-}"; [ $# -gt 0 ] && shift
TENANT=""; SCHEMA=bitmap_dbd; DESIGN=vbitmap_dbd; QUERIES=""; OUT=""
for arg in "$@"; do
    case "$arg" in
        --tenant=*)  TENANT="${arg#*=}" ;;
        --schema=*)  SCHEMA="${arg#*=}" ;;
        --design=*)  DESIGN="${arg#*=}" ;;
        --queries=*) QUERIES="${arg#*=}" ;;
        --out=*)     OUT="${arg#*=}" ;;
        -h|--help)   sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "dbd.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[[ "$SCHEMA" =~ ^[A-Za-z0-9_]+$ && "$DESIGN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "dbd.sh: bad --schema or --design" >&2; exit 2; }
[ "$SCHEMA" != bitmap_demo ] || { echo "dbd.sh: the copy schema must not be bitmap_demo" >&2; exit 2; }
VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { printf '%s\n' "$1" | "${VSQL[@]}"; }
now() { date +%s.%N; }
elapsed() { printf '%.2f' "$(echo "$(now) - $1" | bc)"; }
TABLES="user_profile user_interest event_log device_state asset_state asset_source"

storage() {
    q "SELECT 'storage: table=' || anchor_table_name || ' projection=' || projection_name || ' rows=' || SUM(row_count)
              || ' used_bytes=' || SUM(used_bytes)
       FROM v_monitor.projection_storage WHERE anchor_table_schema = '$SCHEMA'
       GROUP BY anchor_table_name, projection_name ORDER BY anchor_table_name, projection_name"
    q "SELECT 'dbd: op=storage schema=$SCHEMA projections=' || COUNT(DISTINCT projection_name) || ' used_bytes=' || COALESCE(SUM(used_bytes), 0)
       FROM v_monitor.projection_storage WHERE anchor_table_schema = '$SCHEMA'"
}
# ANALYZE_STATISTICS takes a table, projection or column, not a schema (ERROR 2065).
analyze() { for t in $TABLES; do q "SELECT ANALYZE_STATISTICS('$SCHEMA.$t');" > /dev/null; done; }
design_exists() { [ "$(q "SELECT COUNT(*) FROM v_monitor.designs WHERE design_name = '$DESIGN'")" != 0 ]; }
# The Designer's workspace of a design: schemas v_dbd_<design>... They are removed with the design
# (DESIGNER_DROP_DESIGN). The Designer lists a design only until the database restarts: a
# workspace that is still there after a restart can no longer be dropped by name, and
# DESIGNER_CREATE_DESIGN refuses that name. So "design" drops its design as soon as the
# projections are deployed, and a workspace left by something else is reported.
workspace_left() {
    local d; d=$(echo "$DESIGN" | tr 'A-Z' 'a-z')
    [ "$(q "SELECT COUNT(*) FROM v_catalog.schemata WHERE LOWER(schema_name) = 'v_dbd_$d'")" != 0 ]
}
drop_design() {
    if design_exists; then q "SELECT DESIGNER_DROP_DESIGN('$DESIGN', true);" > /dev/null; fi
}

case "$OP" in
copy)
    [[ "$TENANT" =~ ^[0-9]+$ ]] || { echo "dbd.sh: copy needs --tenant=N" >&2; exit 2; }
    [ "$(q "SELECT COUNT(*) FROM v_catalog.schemata WHERE schema_name = '$SCHEMA'")" = 0 ] \
        || { echo "dbd.sh: schema $SCHEMA exists; run bench/dbd.sh drop first" >&2; exit 1; }
    t0=$(now)
    q "CREATE SCHEMA $SCHEMA;"
    for t in $TABLES; do
        t1=$(now)
        q "CREATE TABLE $SCHEMA.$t LIKE bitmap_demo.$t;
           INSERT /*+ DIRECT */ INTO $SCHEMA.$t SELECT * FROM bitmap_demo.$t WHERE tenant_id = $TENANT; COMMIT;"
        echo "dbd: op=copy table=$t rows=$(q "SELECT COUNT(*) FROM $SCHEMA.$t") s=$(elapsed "$t1")"
    done
    t1=$(now)
    analyze
    echo "dbd: op=copy statistics_s=$(elapsed "$t1") total_s=$(elapsed "$t0") tenant=$TENANT schema=$SCHEMA"
    storage
    ;;
design)
    [ -n "$QUERIES" ] && [ -r "$QUERIES" ] || { echo "dbd.sh: design needs a readable --queries=FILE" >&2; exit 2; }
    [ -n "$OUT" ] || { echo "dbd.sh: design needs --out=DIR" >&2; exit 2; }
    mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); QUERIES=$(cd "$(dirname "$QUERIES")" && pwd)/$(basename "$QUERIES")
    drop_design
    if workspace_left; then
        echo "dbd.sh: the database holds a Database Designer workspace of an earlier design $DESIGN that the Designer no longer lists (the database restarted while the design existed): give another name with --design=NAME (bench/reproduce.sh: --dbd-schema=NAME), or remove the workspace with SELECT DESIGNER_DROP_ALL_DESIGNS(); which drops every design of this user" >&2
        exit 1
    fi
    rm -f "$OUT/design.sql" "$OUT/deploy.sql"
    t0=$(now)
    # The design takes the K-safety the database already has (0 on a single node, as in the
    # article). The deployment marks the whole database with the design's value, so a fixed 0
    # would lower the fault tolerance of a cluster.
    ksafe=$(q "SELECT designed_fault_tolerance FROM v_monitor.system")
    [[ "$ksafe" =~ ^[0-9]+$ ]] || { echo "dbd.sh: cannot read the K-safety of the database: $ksafe" >&2; exit 1; }
    trap 'drop_design || true' EXIT     # whatever happens from here on, the design does not stay behind
    q "SELECT DESIGNER_CREATE_DESIGN('$DESIGN');
       SELECT DESIGNER_SET_DESIGN_TYPE('$DESIGN', 'COMPREHENSIVE');
       SELECT DESIGNER_SET_OPTIMIZATION_OBJECTIVE('$DESIGN', 'QUERY');
       SELECT DESIGNER_SET_DESIGN_KSAFETY('$DESIGN', $ksafe);" > /dev/null
    echo "dbd: op=design step=ksafety value=$ksafe (the database's own)"
    echo "dbd: op=design step=tables added=$(q "SELECT DESIGNER_ADD_DESIGN_TABLES('$DESIGN', '$SCHEMA.*', 'true');")"
    q "SELECT DESIGNER_ADD_DESIGN_QUERIES('$DESIGN', '$QUERIES', 'true');" | tr -s ' ' | sed 's/^/dbd: op=design step=queries /'
    q "SELECT design_query_id || ' | weight ' || weight || ' | ' || REGEXP_REPLACE(query_text, '\s+', ' ', 1, 0)
       FROM v_monitor.design_queries WHERE design_name = '$DESIGN' AND design_query_id_index = 0
       ORDER BY design_query_id" > "$OUT/design_queries.txt"
    echo "dbd: op=design step=queries accepted=$(wc -l < "$OUT/design_queries.txt") listed=$OUT/design_queries.txt"
    t1=$(now)
    q "SELECT DESIGNER_RUN_POPULATE_DESIGN_AND_DEPLOY('$DESIGN', '$OUT/design.sql', '$OUT/deploy.sql',
                                                       'true', 'true', 'false', 'false');" > /dev/null
    # The call returns while the deployment (projection refresh, drop of the old superprojections)
    # still runs in the background (seen 2026-11-12): wait for it, then check the catalog.
    q "SELECT DESIGNER_WAIT_FOR_DESIGN('$DESIGN');" > /dev/null
    populate_s=$(elapsed "$t1")
    stale=$(q "SELECT COUNT(*) FROM v_catalog.projections WHERE projection_schema = '$SCHEMA' AND NOT is_up_to_date")
    old=$(q "SELECT COUNT(*) FROM v_catalog.projections WHERE projection_schema = '$SCHEMA' AND projection_name NOT ILIKE '%_DBD_%'")
    [ "$stale" = 0 ] && [ "$old" = 0 ] \
        || { echo "dbd.sh: deployment not complete: $stale projections not up to date, $old not from the design" >&2; exit 1; }
    q "SELECT deployment_operation || ' ' || deployment_projection_type || ' ' || anchor_table_name || ' '
              || deployment_projection_name
       FROM v_monitor.deployment_projections WHERE design_name = '$DESIGN' ORDER BY anchor_table_name, 1" > "$OUT/projections.txt"
    q "SELECT table_name || ' ' || projection_name || ' ' || COALESCE(sort_position::VARCHAR, '-') || ' '
              || projection_column_name || ' ' || encoding_type
       FROM v_catalog.projection_columns WHERE table_schema = '$SCHEMA'
       ORDER BY table_name, projection_name, sort_position IS NULL, sort_position, column_position" > "$OUT/projection_columns.txt"
    for f in "$OUT/design.sql" "$OUT/deploy.sql"; do
        [ -s "$f" ] || { echo "dbd.sh: the designer wrote no $f" >&2; exit 1; }
    done
    t2=$(now)
    analyze
    echo "dbd: op=design populate_deploy_s=$populate_s statistics_s=$(elapsed "$t2") total_s=$(elapsed "$t0")" \
         "deployed=$(grep -c . "$OUT/projections.txt" || true) design_sql=$OUT/design.sql deploy_sql=$OUT/deploy.sql"
    storage | tee "$OUT/storage.txt"
    # the projections are deployed and described: the design and its workspace are not needed any more
    drop_design
    trap - EXIT
    ;;
drop)
    drop_design
    if workspace_left; then echo "dbd: op=drop note: a Designer workspace of an earlier design $DESIGN is left (not listed by the Designer any more)"; fi
    q "DROP SCHEMA IF EXISTS $SCHEMA CASCADE;"
    echo "dbd: op=drop design=$DESIGN schema=$SCHEMA"
    ;;
*) echo "dbd.sh: first argument copy, design or drop (see --help)" >&2; exit 2 ;;
esac

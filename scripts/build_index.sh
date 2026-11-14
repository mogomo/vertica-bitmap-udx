#!/usr/bin/env bash
# Builds bitmap payloads from the predicate catalog (bitmap_demo.bitmap_family). Low-level: it
# writes rows and does not touch the snapshot manifest. scripts/snapshot.sh drives it for the
# lifecycle (build, validate, publish); use this script directly for experiments only.
#
#   scripts/build_index.sh --tenant=N --snapshot=N [--domain=D] [common options]
#                          [--families=a,b] [--via-membership | --aggregate]
#   scripts/build_index.sh --daily --tenant=N --snapshot=N [--aggregate] [common options]
#
# Common options:
#   --source-snapshot=P  read source snapshot P (${snapshot} in the definitions); default N
#   --watermark=TS       value of ${watermark} in the definitions; in daily mode only events
#                        before TS are read. Required when a definition uses ${watermark}.
#   --chunk-bits=16
#   --chunk-filter=SQL   build only chunks for which the condition on chunk_id holds
#   --replace            delete existing rows of the tenant, snapshot and domain first
#                        (index, membership and predicate list); without it, existing rows are
#                        an error
#   --append             add rows to a snapshot that already has rows: no check, no predicate
#                        list, no statistics (the caller does both)
#   --pool=NAME          run the build in this resource pool (SET SESSION RESOURCE_POOL)
#   --echo_only          print the SQL instead of running it
#
# Index mode: for every domain of the tenant (or only --domain), the family definitions (or only
# --families) are combined with UNION ALL and fed to one bm_build pass into
# bitmap_demo.bitmap_index; the predicates built, with family, chunks, cardinality and bytes, go to
# bitmap_demo.bitmap_predicate. Two families producing the same predicate name is an error.
#   --via-membership  first materialize (predicate, chunk_id, local_id) rows in
#                     bitmap_demo.bitmap_membership, then build from that table
#   --aggregate       build with the aggregate function bm_build_agg instead of the transform:
#                     one INSERT ... GROUP BY predicate, chunk per SELECT of each definition, no
#                     sort, every thread of the query. Same payloads byte for byte. Needs an
#                     unfenced deployment (Vertica runs aggregates in the server process only),
#                     16 chunk bits and a memory budget of one 8 KB bitset per (predicate, chunk):
#                     name a pool whose per-query budget holds them (--pool), or the group-by
#                     spills to disk. On input that is not sorted on the keys the states of
#                     every thread must fit as well: at a billion event rows use the transform.
# Daily mode: one set of users per (day, channel) from bitmap_demo.event_log into
# bitmap_demo.daily_bitmap (domain person; day = UTC date of event_ts).
#
# Statistics are refreshed for the key columns only: the payload column holds compressed sets, and
# sampling it costs seconds without telling the optimizer anything.
# A negative or NULL entity ID stops the build with an error (bm_build rejects the local ID).
# Connection: vsql reads VSQL_HOST, VSQL_PORT, VSQL_USER, VSQL_PASSWORD and VSQL_DATABASE.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib_sql.sh

TENANT=""; SNAPSHOT=""; SOURCE=""; WM=""; DOMAIN=""; FAMILIES=""; CB=16; FILTER=""
VIA=no; REPLACE=no; APPEND=no; DAILY=no; ECHO_ONLY=no; AGG=no; POOL=""
for arg in "$@"; do
    case "$arg" in
        --tenant=*)          TENANT="${arg#*=}" ;;
        --snapshot=*)        SNAPSHOT="${arg#*=}" ;;
        --source-snapshot=*) SOURCE="${arg#*=}" ;;
        --watermark=*)       WM="${arg#*=}" ;;
        --domain=*)          DOMAIN="${arg#*=}" ;;
        --families=*)        FAMILIES="${arg#*=}" ;;
        --chunk-bits=*)      CB="${arg#*=}" ;;
        --chunk-filter=*)    FILTER="${arg#*=}" ;;
        --via-membership)    VIA=yes ;;
        --aggregate)         AGG=yes ;;
        --pool=*)            POOL="${arg#*=}" ;;
        --replace)           REPLACE=yes ;;
        --append)            APPEND=yes ;;
        --daily)             DAILY=yes ;;
        --echo_only)         ECHO_ONLY=yes ;;
        -h|--help)           sed -n '2,43p' "$0"; exit 0 ;;
        *) echo "build_index.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
SOURCE="${SOURCE:-$SNAPSHOT}"
int_re='^[0-9]+$'
[[ "$TENANT" =~ $int_re && "$SNAPSHOT" =~ $int_re && "$SOURCE" =~ $int_re && "$CB" =~ $int_re ]] \
    || { echo "build_index.sh: --tenant, --snapshot, --source-snapshot and --chunk-bits must be integers" >&2; exit 2; }
[[ -z "$DOMAIN" || "$DOMAIN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "build_index.sh: bad --domain" >&2; exit 2; }
[[ -z "$FAMILIES" || "$FAMILIES" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || { echo "build_index.sh: bad --families" >&2; exit 2; }
[ -z "$FAMILIES" ] || [ -n "$DOMAIN" ] || { echo "build_index.sh: --families needs --domain" >&2; exit 2; }
[ -z "$WM" ] || ts_literal "$WM" > /dev/null || exit 2
[ "$REPLACE" = no ] || [ "$APPEND" = no ] || { echo "build_index.sh: --replace and --append exclude each other" >&2; exit 2; }
[ "$VIA" = no ] || [ "$APPEND" = no ] || { echo "build_index.sh: --via-membership and --append exclude each other" >&2; exit 2; }
[ "$VIA" = no ] || [ "$AGG" = no ] || { echo "build_index.sh: --via-membership and --aggregate exclude each other" >&2; exit 2; }
[ "$AGG" = no ] || [ "$CB" = 16 ] || { echo "build_index.sh: --aggregate builds chunks of 16 bits only" >&2; exit 2; }
[[ -z "$POOL" || "$POOL" =~ ^[A-Za-z0-9_]+$ ]] || { echo "build_index.sh: bad --pool" >&2; exit 2; }
MASK=$(( (1 << CB) - 1 ))
SESSION=""
[ -n "$POOL" ] && SESSION="SET SESSION RESOURCE_POOL = $POOL;"
CHUNK_WHERE="TRUE"
[ -n "$FILTER" ] && CHUNK_WHERE="($FILTER)"

VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)

run() {   # run SQL text (or print it)
    if [ "$ECHO_ONLY" = yes ]; then printf '%s\n' "$1"; return 0; fi
    printf '%s\n' "$1" | "${VSQL[@]}" > /dev/null
}

# entity ID -> (chunk_id, local_id) columns; NULL stays NULL and a negative ID becomes -1, both
# rejected by bm_build.
chunk_cols() {
    echo "$1 >> $CB AS chunk_id, CASE WHEN $1 IS NULL THEN NULL WHEN $1 < 0 THEN -1 ELSE $1 & $MASK END AS local_id"
}

existing() {   # existing rows of a table for the scope
    "${VSQL[@]}" -c "SELECT COUNT(*) FROM bitmap_demo.$1 WHERE tenant_id = $TENANT AND snapshot_id = $SNAPSHOT $2"
}

if [ "$AGG" = yes ] && [ "$ECHO_ONLY" = no ] && \
   [ "$("${VSQL[@]}" -c "SELECT COUNT(*) FROM v_catalog.user_functions WHERE schema_name = 'vbitmap' AND function_name = 'bm_build_agg'")" = 0 ]; then
    echo "build_index.sh: --aggregate needs the aggregate functions of an unfenced deployment (scripts/deploy.sh --fenced=no)" >&2
    exit 1
fi

start=$(date +%s.%N)

if [ "$DAILY" = yes ]; then
    if [ "$ECHO_ONLY" = no ] && [ "$APPEND" = no ] && [ "$(existing daily_bitmap "")" != 0 ]; then
        [ "$REPLACE" = yes ] || { echo "build_index.sh: daily_bitmap already has rows for tenant $TENANT snapshot $SNAPSHOT (use --replace)" >&2; exit 1; }
        run "DELETE FROM bitmap_demo.daily_bitmap WHERE tenant_id = $TENANT AND snapshot_id = $SNAPSHOT; COMMIT;"
    fi
    before="TRUE"
    [ -n "$WM" ] && before="event_ts < $(ts_literal "$WM")"
    events="SELECT * FROM (
        SELECT tenant_id, $SNAPSHOT AS snapshot_id, event_ts::DATE AS day, channel, 'person'::VARCHAR(16) AS domain,
               $(chunk_cols user_id)
        FROM bitmap_demo.event_log WHERE tenant_id = $TENANT AND $before) e
      WHERE $CHUNK_WHERE"
    if [ "$AGG" = yes ]; then
        run "$SESSION
INSERT /*+DIRECT*/ INTO bitmap_demo.daily_bitmap (tenant_id, snapshot_id, day, channel, domain, chunk_id, payload)
SELECT tenant_id, snapshot_id, day, channel, domain, chunk_id, vbitmap.bm_build_agg(local_id)
FROM ($events) k
GROUP BY tenant_id, snapshot_id, day, channel, domain, chunk_id;
COMMIT;"
    else
        run "$SESSION
INSERT /*+DIRECT*/ INTO bitmap_demo.daily_bitmap (tenant_id, snapshot_id, day, channel, domain, chunk_id, payload)
SELECT vbitmap.bm_build(tenant_id, snapshot_id, day, channel, domain, chunk_id, local_id USING PARAMETERS chunk_bits = $CB)
       OVER (PARTITION BY tenant_id, snapshot_id, day, channel, domain, chunk_id)
FROM ($events) k;
COMMIT;"
    fi
    [ "$APPEND" = yes ] && exit 0
    run "SELECT ANALYZE_STATISTICS('bitmap_demo.daily_bitmap', 'tenant_id, snapshot_id, day, channel, domain, chunk_id');" > /dev/null
    [ "$ECHO_ONLY" = yes ] && exit 0
    "${VSQL[@]}" -c "SELECT 'daily_bitmap: ' || COUNT(*) || ' payloads, ' || COALESCE(SUM(LENGTH(payload)), 0) || ' bytes, '
                            || COUNT(DISTINCT day) || ' days, ' || COUNT(DISTINCT channel) || ' channels'
                     FROM bitmap_demo.daily_bitmap WHERE tenant_id = $TENANT AND snapshot_id = $SNAPSHOT"
    echo "elapsed: $(echo "$(date +%s.%N) - $start" | bc) s"
    exit 0
fi

# ---- index mode ------------------------------------------------------------------------------
if [ -n "$DOMAIN" ]; then
    domains="$DOMAIN"
else
    domains=$("${VSQL[@]}" -c "SELECT DISTINCT domain FROM bitmap_demo.bitmap_family WHERE tenant_id = $TENANT ORDER BY 1")
fi
[ -n "$domains" ] || { echo "build_index.sh: no families for tenant $TENANT" >&2; exit 1; }

for dom in $domains; do
    [[ "$dom" =~ ^[A-Za-z0-9_]+$ ]] || { echo "build_index.sh: bad domain name in the catalog: $dom" >&2; exit 1; }
    # shellcheck disable=SC2086
    source_sql=$(family_union_sql "$TENANT" "$SOURCE" "$WM" "$dom" ${FAMILIES//,/ }) || exit 1
    scope="AND domain = '$dom'"
    where="WHERE tenant_id = $TENANT AND snapshot_id = $SNAPSHOT $scope"
    if [ "$ECHO_ONLY" = no ] && [ "$APPEND" = no ] && [ "$(existing bitmap_index "$scope")" != 0 ]; then
        [ "$REPLACE" = yes ] || { echo "build_index.sh: bitmap_index already has rows for tenant $TENANT snapshot $SNAPSHOT domain $dom (use --replace)" >&2; exit 1; }
        run "DELETE FROM bitmap_demo.bitmap_index $where;
DELETE FROM bitmap_demo.bitmap_membership $where;
DELETE FROM bitmap_demo.bitmap_predicate $where; COMMIT;"
    fi
    if [ "$AGG" = yes ]; then
        # The aggregate builder fills the same temporary table as the transform, with one statement
        # per SELECT of each family definition; the index then receives it in one INSERT (one
        # storage container), and the checks and the predicate list below are the same.
        stmts=""
        while IFS= read -r -d $'\x1e' rec; do
            fam="${rec%%$'\x1f'*}"; branch="${rec#*$'\x1f'}"
            stmts+="INSERT /*+DIRECT*/ INTO vb_built (tenant_id, snapshot_id, domain, family, predicate, chunk_id, payload)
  SELECT $TENANT, $SNAPSHOT, '$dom', '$fam', predicate, chunk_id, payload FROM (
    SELECT predicate::VARCHAR(80) AS predicate, chunk_id, vbitmap.bm_build_agg(local_id) AS payload
    FROM (SELECT predicate, $(chunk_cols entity_id) FROM (
$branch) AS s (predicate, entity_id)) k
    WHERE $CHUNK_WHERE GROUP BY 1, 2) f;
"
        done < <(family_branches "$TENANT" "$SOURCE" "$WM" "$dom" ${FAMILIES//,/ }) || exit 1
        [ -n "$stmts" ] || { echo "build_index.sh: no family definitions for tenant $TENANT domain $dom" >&2; exit 1; }
        prepare="CREATE LOCAL TEMP TABLE vb_built (tenant_id INT, snapshot_id INT, domain VARCHAR(16), family VARCHAR(40),
    predicate VARCHAR(80), chunk_id INT, payload VARBINARY(16384) ENCODING ZSTD_FAST_COMP)
  ON COMMIT PRESERVE ROWS ORDER BY chunk_id, predicate;
$stmts"
    fi
    keyed="SELECT * FROM (
        SELECT $TENANT AS tenant_id, $SNAPSHOT AS snapshot_id, '$dom'::VARCHAR(16) AS domain,
               family::VARCHAR(40) AS family, predicate::VARCHAR(80) AS predicate, $(chunk_cols entity_id)
        FROM ($source_sql) s) k
      WHERE $CHUNK_WHERE"
    build="vbitmap.bm_build(tenant_id, snapshot_id, domain, family, predicate, chunk_id, local_id USING PARAMETERS chunk_bits = $CB)
       OVER (PARTITION BY tenant_id, snapshot_id, domain, family, predicate, chunk_id)"
    if [ "$AGG" = yes ]; then
        :
    elif [ "$VIA" = yes ]; then
        # Memberships are materialized first; the family of each predicate is kept aside.
        prepare="CREATE LOCAL TEMP TABLE vb_keyed ON COMMIT PRESERVE ROWS AS $keyed;
INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_membership (tenant_id, snapshot_id, domain, predicate, chunk_id, local_id)
  SELECT tenant_id, snapshot_id, domain, predicate, chunk_id, local_id FROM vb_keyed;
COMMIT;
CREATE LOCAL TEMP TABLE vb_built ON COMMIT PRESERVE ROWS AS
SELECT $build
FROM (SELECT m.tenant_id, m.snapshot_id, m.domain, f.family, m.predicate, m.chunk_id, m.local_id
      FROM bitmap_demo.bitmap_membership m
      JOIN (SELECT DISTINCT family, predicate FROM vb_keyed) f ON f.predicate = m.predicate
      WHERE m.tenant_id = $TENANT AND m.snapshot_id = $SNAPSHOT AND m.domain = '$dom') x;"
    else
        prepare="CREATE LOCAL TEMP TABLE vb_built ON COMMIT PRESERVE ROWS AS
SELECT $build
FROM ($keyed) m;"
    fi
    predicates="INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_predicate (tenant_id, snapshot_id, domain, family, predicate, chunks, cardinality, bytes)
  SELECT tenant_id, snapshot_id, domain, family, predicate, COUNT(*), SUM(vbitmap.bm_cardinality(payload)), SUM(LENGTH(payload))
  FROM vb_built GROUP BY tenant_id, snapshot_id, domain, family, predicate;"
    [ "$APPEND" = yes ] && predicates=""
    # One statement batch, one session: the temporary tables live until it ends.
    run "$SESSION
$prepare
SELECT CASE WHEN COUNT(*) = 0 THEN 'ok' ELSE THROW_ERROR('predicate names shared by two families: ' || MIN(predicate)) END
FROM (SELECT predicate FROM vb_built GROUP BY predicate HAVING COUNT(DISTINCT family) > 1) d;
INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_index (tenant_id, snapshot_id, domain, predicate, chunk_id, payload)
  SELECT tenant_id, snapshot_id, domain, predicate, chunk_id, payload FROM vb_built;
$predicates
COMMIT;"
    if [ "$ECHO_ONLY" = no ] && [ "$APPEND" = no ]; then
        "${VSQL[@]}" -c "SELECT '$dom: ' || COUNT(*) || ' predicates, ' || COALESCE(SUM(chunks), 0) || ' payloads, '
                                || COALESCE(SUM(bytes), 0) || ' bytes in ' || COUNT(DISTINCT family) || ' families'
                         FROM bitmap_demo.bitmap_predicate $where"
    fi
done
[ "$APPEND" = yes ] && exit 0
run "SELECT ANALYZE_STATISTICS('bitmap_demo.bitmap_index', 'tenant_id, snapshot_id, domain, predicate, chunk_id'); SELECT ANALYZE_STATISTICS('bitmap_demo.bitmap_predicate');" > /dev/null
[ "$ECHO_ONLY" = yes ] || echo "elapsed: $(echo "$(date +%s.%N) - $start" | bc) s"

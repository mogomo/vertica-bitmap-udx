#!/usr/bin/env bash
# ClickHouse side of the cross-engine comparison (plan section 17, D13): same data, same sets.
#
#   bench/ch.sh export  --tenant=N [--dir=/data/xbench/export]      Vertica up: tables to TSV files
#   bench/ch.sh load    --tenant=N [--dir=/data/xbench/export]      ClickHouse up: schema + load + merge
#   bench/ch.sh build   --tenant=N [--snapshot=1] [--source-snapshot=S] [--watermark=TS]
#                       [--device-watermark=TS] [--only=person,daily,device]
#   bench/ch.sh build-bits --tenant=N [--snapshot=1] [--source-snapshot=S]   age as bit-sliced sets
#   bench/ch.sh drop-snapshot --tenant=N --snapshot=S                remove the sets of one snapshot
#   bench/ch.sh live-create                                         tag table + sets kept by a materialized view
#   bench/ch.sh live-load   --tenant=N [--source-snapshot=1]         tag rows from the source tables (same families)
#   bench/ch.sh live-batch  --tenant=N [--dir=...]                   staging rows from DIR/tN/batch_tag.tsv
#   bench/ch.sh live-append --tenant=N                               timed: staging rows appended to the tag table
#   bench/ch.sh storage
#   bench/ch.sh quiet                                               wait until no merge or mutation runs
#
# export  writes user_profile, user_interest, event_log, device_state of one tenant (the tables of the
#         headline queries) as TSV (NULL as \N, booleans as true/false) and the row count of each.
# load    drops and creates database xbench (bench/engines/clickhouse/schema.sql), loads the files,
#         compares row counts with the export, then OPTIMIZE ... FINAL so that no background merge
#         runs during a measurement.
# build   the bitmaps, timed per step: person (families of sql/families.sql), daily sets (as
#         scripts/build_index.sh --daily: events before the watermark, per UTC day and channel),
#         device (the device families at the device watermark). Comparable with the build step of
#         scripts/snapshot.sh (build_s, without its validation). Existing sets of the same
#         (tenant, snapshot) are deleted first; other snapshots stay readable (refresh under load:
#         build snapshot 2 while readers use snapshot 1). --source-snapshot names the source rows
#         the sets are built from (default: the same number as --snapshot); a build that finds no
#         source row for a requested kind of set fails instead of reporting an empty result.
# build-bits  adds the sets age_bit_0 ... age_bit_7 (people whose age has that bit set) to the person
#         sets of the snapshot: the family of sql/families_bitsliced.sql, for the join-free totals of
#         bench/workloads/clickhouse_ids.sql (q8.agg.C). Existing age_bit sets are replaced.
# live-*  ClickHouse's counterpart of Vertica's live projection (scripts/live_index.sh): a tag table
#         (tenant, snapshot, predicate, entity), an AggregatingMergeTree table of groupBitmap states
#         (xbench.live_bitmap) and a materialized view that adds the states of every inserted block.
#         live-append inserts the staging rows (bench/live_append.sh batch --export) and then
#         compares one touched set with uniqExact on the tag table.
# Lines: "ch: op=... key=value ...". Connection: clickhouse-client on ::1 (server.sh).
set -euo pipefail

cd "$(dirname "$0")/.."
OP="${1:-}"; [ $# -gt 0 ] && shift
TENANT=""; DIR=/data/xbench/export; SNAP=1; SRC=""; ONLY=person,daily,device; WM="2026-11-01 00:00:00"; DWM="2026-11-01 12:00:00"
for arg in "$@"; do
    case "$arg" in
        --tenant=*)           TENANT="${arg#*=}" ;;
        --dir=*)              DIR="${arg#*=}" ;;
        --snapshot=*)         SNAP="${arg#*=}" ;;
        --source-snapshot=*)  SRC="${arg#*=}" ;;
        --watermark=*)        WM="${arg#*=}" ;;
        --device-watermark=*) DWM="${arg#*=}" ;;
        --only=*)             ONLY="${arg#*=}" ;;
        -h|--help)            sed -n '2,38p' "$0"; exit 0 ;;
        *) echo "ch.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[ -z "$TENANT" ] || [[ "$TENANT" =~ ^[0-9]+$ ]] || { echo "ch.sh: bad --tenant" >&2; exit 2; }
[[ "$SNAP" =~ ^[0-9]+$ ]] || { echo "ch.sh: bad --snapshot" >&2; exit 2; }
SRC=${SRC:-$SNAP}
[[ "$SRC" =~ ^[0-9]+$ ]] || { echo "ch.sh: bad --source-snapshot" >&2; exit 2; }
ts_re='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
[[ "$WM" =~ $ts_re && "$DWM" =~ $ts_re ]] || { echo "ch.sh: watermarks as YYYY-MM-DD HH:MM:SS" >&2; exit 2; }
[[ ",$ONLY," =~ ^(,(person|daily|device))+,$ ]] || { echo "ch.sh: --only: person, daily, device" >&2; exit 2; }
want() { [[ ",$ONLY," == *",$1,"* ]]; }
need_tenant() { [ -n "$TENANT" ] || { echo "ch.sh: $OP needs --tenant=N" >&2; exit 2; }; }

CH=(clickhouse-client --host ::1 --port 9000)
ch() { "${CH[@]}" --multiquery --query "$1"; }
VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
now() { date +%s.%N; }
elapsed() { printf '%.2f' "$(echo "$(now) - $1" | bc)"; }
TABLES="user_profile user_interest event_log device_state"

export_sql() {   # TABLE -> the SELECT of its export
    local w="WHERE tenant_id = $TENANT"
    case "$1" in
        user_profile)  echo "SELECT tenant_id, snapshot_id, entity_id, country, age,
                               CASE WHEN consent THEN 'true' WHEN NOT consent THEN 'false' END,
                               CASE WHEN suspended THEN 'true' WHEN NOT suspended THEN 'false' END
                        FROM bitmap_demo.user_profile $w" ;;
        user_interest) echo "SELECT tenant_id, snapshot_id, entity_id, topic FROM bitmap_demo.user_interest $w" ;;
        event_log)     echo "SELECT tenant_id, event_id, user_id, TO_CHAR(event_ts, 'YYYY-MM-DD HH24:MI:SS'), channel
                        FROM bitmap_demo.event_log $w" ;;
        device_state)  echo "SELECT tenant_id, snapshot_id, device_id,
                               CASE WHEN online THEN 'true' WHEN NOT online THEN 'false' END, zone,
                               temp_tenths, changes_10m, TO_CHAR(observed_at, 'YYYY-MM-DD HH24:MI:SS')
                        FROM bitmap_demo.device_state $w" ;;
    esac
}

storage() {
    ch "SELECT 'storage: engine=clickhouse table=' || table || ' rows=' || toString(sum(rows))
               || ' bytes_on_disk=' || toString(sum(bytes_on_disk))
               || ' compressed_bytes=' || toString(sum(data_compressed_bytes))
               || ' uncompressed_bytes=' || toString(sum(data_uncompressed_bytes)) || ' parts=' || toString(count())
        FROM system.parts WHERE database = 'xbench' AND active GROUP BY table ORDER BY table
        FORMAT TSVRaw"
}

quiet() {
    local n
    for _ in $(seq 1 1800); do
        n=$("${CH[@]}" --query "SELECT (SELECT count() FROM system.merges) + (SELECT count() FROM system.mutations WHERE NOT is_done)")
        [ "$n" = 0 ] && return 0
        sleep 1
    done
    echo "ch.sh: merges still running after 30 min" >&2; return 1
}

drop_snapshot() {   # sets of (TENANT, SNAP) in the three bitmap tables, removed synchronously
    local t
    for t in person_bitmap daily_bitmap device_bitmap; do
        [ "$("${CH[@]}" --query "SELECT count() FROM xbench.$t WHERE tenant_id = $TENANT AND snapshot_id = $SNAP")" = 0 ] \
            || ch "ALTER TABLE xbench.$t DELETE WHERE tenant_id = $TENANT AND snapshot_id = $SNAP SETTINGS mutations_sync = 2"
    done
}

case "$OP" in
export)
    need_tenant
    d="$DIR/t$TENANT"; mkdir -p "$d"
    t0=$(now)
    for t in $TABLES; do
        t1=$(now)
        "${VSQL[@]}" -F $'\t' -P null='\N' -o "$d/$t.tsv" -c "$(export_sql "$t")"
        n=$(wc -l < "$d/$t.tsv" | tr -d ' ')
        v=$("${VSQL[@]}" -c "SELECT COUNT(*) FROM bitmap_demo.$t WHERE tenant_id = $TENANT")
        [ "$n" = "$v" ] || { echo "ch.sh: $t: $n lines written, $v rows in Vertica" >&2; exit 1; }
        echo "$n" > "$d/$t.count"
        echo "ch: op=export table=$t rows=$n bytes=$(stat -c %s "$d/$t.tsv") s=$(elapsed "$t1")"
    done
    echo "ch: op=export tenant=$TENANT dir=$d total_s=$(elapsed "$t0")" ;;
load)
    need_tenant
    d="$DIR/t$TENANT"
    t0=$(now)
    ch "DROP DATABASE IF EXISTS xbench SYNC"
    ch "$(grep -v '^--' bench/engines/clickhouse/schema.sql)"
    for t in $TABLES; do
        t1=$(now)
        "${CH[@]}" --query "INSERT INTO xbench.$t FORMAT TSV" < "$d/$t.tsv"
        n=$("${CH[@]}" --query "SELECT count() FROM xbench.$t")
        [ "$n" = "$(cat "$d/$t.count")" ] || { echo "ch.sh: $t: $n rows loaded, $(cat "$d/$t.count") exported" >&2; exit 1; }
        t2=$(now)
        ch "OPTIMIZE TABLE xbench.$t FINAL"
        echo "ch: op=load table=$t rows=$n load_s=$(printf '%.2f' "$(echo "$t2 - $t1" | bc)") optimize_s=$(elapsed "$t2")"
    done
    quiet
    echo "ch: op=load tenant=$TENANT total_s=$(elapsed "$t0")"
    storage ;;
build)
    need_tenant
    k="tenant_id = $TENANT AND snapshot_id = $SRC"
    win="observed_at > toDateTime('$DWM', 'UTC') - INTERVAL 30 MINUTE AND observed_at <= toDateTime('$DWM', 'UTC')"
    drop_snapshot
    t0=$(now)
    person_s=-; daily_s=-; device_s=-
    t1=$(now)
    want person && ch "INSERT INTO xbench.person_bitmap
        SELECT $TENANT, $SNAP, predicate, groupBitmapState(entity_id) FROM (
          SELECT 'all' AS predicate, entity_id FROM xbench.user_profile WHERE $k
          UNION ALL SELECT concat('country_', assumeNotNull(country)), entity_id FROM xbench.user_profile WHERE $k AND country IS NOT NULL
          UNION ALL SELECT 'age_25_54', entity_id FROM xbench.user_profile WHERE $k AND age BETWEEN 25 AND 54
          UNION ALL SELECT 'age_known', entity_id FROM xbench.user_profile WHERE $k AND age IS NOT NULL
          UNION ALL SELECT if(assumeNotNull(consent), 'consent_true', 'consent_false'), entity_id FROM xbench.user_profile WHERE $k AND consent IS NOT NULL
          UNION ALL SELECT if(assumeNotNull(suspended), 'suspended_true', 'suspended_false'), entity_id FROM xbench.user_profile WHERE $k AND suspended IS NOT NULL
          UNION ALL SELECT concat('topic_', topic), entity_id FROM xbench.user_interest WHERE $k)
        GROUP BY predicate" && person_s=$(elapsed "$t1")
    t1=$(now)
    want daily && ch "INSERT INTO xbench.daily_bitmap
        SELECT $TENANT, $SNAP, toDate(event_ts) AS day, channel, groupBitmapState(user_id)
        FROM xbench.event_log WHERE tenant_id = $TENANT AND event_ts < toDateTime('$WM', 'UTC')
        GROUP BY day, channel" && daily_s=$(elapsed "$t1")
    t1=$(now)
    want device && ch "INSERT INTO xbench.device_bitmap
        SELECT $TENANT, $SNAP, predicate, groupBitmapState(device_id) FROM (
          SELECT if(assumeNotNull(online), 'online_true', 'online_false') AS predicate, device_id FROM xbench.device_state WHERE $k AND online IS NOT NULL AND $win
          UNION ALL SELECT concat('zone_', assumeNotNull(zone)), device_id FROM xbench.device_state WHERE $k AND zone IS NOT NULL AND $win
          UNION ALL SELECT 'temp_ge_800', device_id FROM xbench.device_state WHERE $k AND temp_tenths >= 800 AND $win
          UNION ALL SELECT 'changes_gt_3', device_id FROM xbench.device_state WHERE $k AND changes_10m > 3 AND $win)
        GROUP BY predicate" && device_s=$(elapsed "$t1")
    total_s=$(elapsed "$t0")
    quiet
    w="WHERE tenant_id = $TENANT AND snapshot_id = $SNAP"
    counts=$("${CH[@]}" --query "SELECT (SELECT count() FROM xbench.person_bitmap $w) || ' ' || (SELECT count() FROM xbench.daily_bitmap $w) || ' ' || (SELECT count() FROM xbench.device_bitmap $w)")
    read -r np nd ndev <<< "$counts"
    # a requested kind of set that came out empty means the source rows were not found
    { want person && [ "$np" = 0 ]; } && { echo "ch.sh: build: no person set built (no source rows of snapshot $SRC?)" >&2; exit 1; }
    { want daily && [ "$nd" = 0 ]; } && { echo "ch.sh: build: no daily set built" >&2; exit 1; }
    { want device && [ "$ndev" = 0 ]; } && { echo "ch.sh: build: no device set built (no source rows of snapshot $SRC?)" >&2; exit 1; }
    echo "ch: op=build tenant=$TENANT snapshot=$SNAP source_snapshot=$SRC person_s=$person_s person_sets=$np daily_s=$daily_s daily_sets=$nd device_s=$device_s device_sets=$ndev total_s=$total_s"
    storage ;;
build-bits)
    need_tenant
    k="tenant_id = $TENANT AND snapshot_id = $SRC"
    w="tenant_id = $TENANT AND snapshot_id = $SNAP AND startsWith(predicate, 'age_bit_')"
    [ "$("${CH[@]}" --query "SELECT count() FROM xbench.person_bitmap WHERE $w")" = 0 ] \
        || ch "ALTER TABLE xbench.person_bitmap DELETE WHERE $w SETTINGS mutations_sync = 2"
    t0=$(now)
    ch "INSERT INTO xbench.person_bitmap
        SELECT $TENANT, $SNAP, concat('age_bit_', toString(b)), groupBitmapState(entity_id)
        FROM xbench.user_profile ARRAY JOIN range(8) AS b
        WHERE $k AND age IS NOT NULL AND bitAnd(bitShiftRight(assumeNotNull(age), b), 1) = 1
        GROUP BY b"
    s=$(elapsed "$t0")
    quiet
    n=$("${CH[@]}" --query "SELECT uniqExact(predicate) FROM xbench.person_bitmap WHERE $w")
    [ "$n" != 0 ] || { echo "ch.sh: build-bits: no set built (no source rows of snapshot $SRC?)" >&2; exit 1; }
    sum=$("${CH[@]}" --query "SELECT sum(bitmapCardinality(bm) * bitShiftLeft(toUInt64(1), toUInt8(substring(predicate, 9)))) FROM (SELECT predicate, groupBitmapMergeState(bm) AS bm FROM xbench.person_bitmap WHERE $w GROUP BY predicate)")
    native=$("${CH[@]}" --query "SELECT sum(age) FROM xbench.user_profile WHERE $k")
    echo "ch: op=build-bits tenant=$TENANT snapshot=$SNAP source_snapshot=$SRC sets=$n s=$s weighted_sum=$sum native_sum=$native equal=$([ "$sum" = "$native" ] && echo yes || echo NO)"
    [ "$sum" = "$native" ]
    storage ;;
drop-snapshot)
    need_tenant
    drop_snapshot
    echo "ch: op=drop-snapshot tenant=$TENANT snapshot=$SNAP" ;;
live-create)
    ch "DROP VIEW IF EXISTS xbench.live_bitmap_mv; DROP TABLE IF EXISTS xbench.live_bitmap; DROP TABLE IF EXISTS xbench.tag; DROP TABLE IF EXISTS xbench.batch_tag;
        CREATE TABLE xbench.tag (tenant_id UInt32, snapshot_id UInt32, predicate LowCardinality(String), entity_id UInt32)
          ENGINE = MergeTree ORDER BY (tenant_id, snapshot_id, predicate, entity_id);
        CREATE TABLE xbench.batch_tag (tenant_id UInt32, snapshot_id UInt32, predicate LowCardinality(String), entity_id UInt32)
          ENGINE = MergeTree ORDER BY (tenant_id, snapshot_id, predicate, entity_id);
        CREATE TABLE xbench.live_bitmap (tenant_id UInt32, snapshot_id UInt32, predicate LowCardinality(String),
                                         bm AggregateFunction(groupBitmap, UInt32))
          ENGINE = AggregatingMergeTree ORDER BY (tenant_id, snapshot_id, predicate);
        CREATE MATERIALIZED VIEW xbench.live_bitmap_mv TO xbench.live_bitmap AS
          SELECT tenant_id, snapshot_id, predicate, groupBitmapState(entity_id) AS bm
          FROM xbench.tag GROUP BY tenant_id, snapshot_id, predicate"
    echo "ch: op=live-create tables=tag,batch_tag,live_bitmap view=live_bitmap_mv" ;;
live-load)
    need_tenant
    k="tenant_id = $TENANT AND snapshot_id = $SRC"
    t0=$(now)
    ch "INSERT INTO xbench.tag
        SELECT $TENANT, $SRC, predicate, entity_id FROM (
          SELECT 'all' AS predicate, entity_id FROM xbench.user_profile WHERE $k
          UNION ALL SELECT concat('country_', assumeNotNull(country)), entity_id FROM xbench.user_profile WHERE $k AND country IS NOT NULL
          UNION ALL SELECT 'age_25_54', entity_id FROM xbench.user_profile WHERE $k AND age BETWEEN 25 AND 54
          UNION ALL SELECT 'age_known', entity_id FROM xbench.user_profile WHERE $k AND age IS NOT NULL
          UNION ALL SELECT if(assumeNotNull(consent), 'consent_true', 'consent_false'), entity_id FROM xbench.user_profile WHERE $k AND consent IS NOT NULL
          UNION ALL SELECT if(assumeNotNull(suspended), 'suspended_true', 'suspended_false'), entity_id FROM xbench.user_profile WHERE $k AND suspended IS NOT NULL
          UNION ALL SELECT concat('topic_', topic), entity_id FROM xbench.user_interest WHERE $k)"
    load_s=$(elapsed "$t0")
    t1=$(now)
    ch "OPTIMIZE TABLE xbench.tag FINAL; OPTIMIZE TABLE xbench.live_bitmap FINAL"
    quiet
    n=$("${CH[@]}" --query "SELECT count() FROM xbench.tag")
    sets=$("${CH[@]}" --query "SELECT uniqExact(predicate) FROM xbench.live_bitmap WHERE tenant_id = $TENANT AND snapshot_id = $SRC")
    echo "ch: op=live-load tenant=$TENANT rows=$n load_s=$load_s optimize_s=$(elapsed "$t1") sets=$sets"
    storage ;;
live-batch)
    need_tenant
    f="$DIR/t$TENANT/batch_tag.tsv"
    [ -s "$f" ] || { echo "ch.sh: $f is missing (bench/live_append.sh batch --export)" >&2; exit 1; }
    ch "TRUNCATE TABLE xbench.batch_tag"
    "${CH[@]}" --query "INSERT INTO xbench.batch_tag FORMAT TSV" < "$f"
    ch "OPTIMIZE TABLE xbench.batch_tag FINAL"
    echo "ch: op=live-batch tenant=$TENANT rows=$("${CH[@]}" --query "SELECT count() FROM xbench.batch_tag") lines=$(wc -l < "$f" | tr -d ' ')" ;;
live-append)
    need_tenant
    t0=$(now)
    ch "INSERT INTO xbench.tag SELECT * FROM xbench.batch_tag"
    s=$(elapsed "$t0")
    n=$("${CH[@]}" --query "SELECT count() FROM xbench.batch_tag")
    p=$("${CH[@]}" --query "SELECT min(predicate) FROM xbench.batch_tag")
    live=$("${CH[@]}" --query "SELECT groupBitmapMerge(bm) FROM xbench.live_bitmap WHERE tenant_id = $TENANT AND snapshot_id = 1 AND predicate = '$p'")
    native=$("${CH[@]}" --query "SELECT uniqExact(entity_id) FROM xbench.tag WHERE tenant_id = $TENANT AND snapshot_id = 1 AND predicate = '$p'")
    echo "ch: op=live-append engine=clickhouse tenant=$TENANT rows=$n s=$s check_set=$p live=$live native=$native equal=$([ "$live" = "$native" ] && echo yes || echo NO) parts=$("${CH[@]}" --query "SELECT count() FROM system.parts WHERE database = 'xbench' AND table = 'live_bitmap' AND active")"
    [ "$live" = "$native" ] ;;
storage) storage ;;
quiet)   quiet; echo "ch: op=quiet merges=0" ;;
*) echo "ch.sh: first argument export, load, build, build-bits, drop-snapshot, live-create, live-load, live-batch, live-append, storage or quiet (see --help)" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# Chain 14: the ID-list tests on equal terms, what an ID list is used for, and the live index.
#
# Why: in the earlier comparison the driver read Vertica through one vsql process per client (which
# formats every row and writes it to a pipe) and ClickHouse through a raw HTTP read, and at 32
# clients both ran against two client CPUs; the ID-list numbers therefore measured the client
# programs. Here the driver reads both engines the same way (--client=socket: Vertica's wire
# protocol, clock stopped at the last byte), and the list is also measured where it is used:
# consumed inside the engine, joined to the profile table, saved as a set, saved as a table.
# New in the library: bm_ids_text (the ID list as text blocks). New index form: schema bitmap_live,
# live aggregate projections that keep the sets up to date on every load (scripts/live_index.sh);
# ClickHouse's counterpart is a materialized view into an AggregatingMergeTree table
# (bench/ch.sh live-*). Every statement is capped.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5c"
RC="bench/record.sh --area=clickhouse --engine=clickhouse --milestone=M5c"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
EXP=/data/xbench/export/t10
D="python3 bench/driver.py"
ROWS=q1.ids.Bplus,q4.Bplus,q8.Bplus,q1.ids.text.Bplus,q4.text.Bplus,q8.text.Bplus
USE=q1.ids.sum.Bplus,q4.sum.Bplus,q8.sum.Bplus,q8.join.Bplus
SAVE=q8.save.set.Bplus,q8.save.ids.Bplus
LIVE_H=q1.count.Bplus,q3.Bplus,q8.Bplus
LIVE_MIX=q1.count.Bplus,q3.Bplus
LIVE_I=q1.ids.text.Bplus,q8.text.Bplus,q8.sum.Bplus,q8.join.Bplus
vrun() {   # NAME PURPOSE PATH WORKLOAD CLIENTS ONLY [driver options]
    local name=$1 purpose=$2 path=$3 wl=$4 clients=$5 only=$6; shift 6
    $RV --run="$name" --purpose="$purpose" --scale="tenant 10" --path="$path" -- bash -c "$D run --client socket --workload bench/workloads/$wl --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients $clients --iterations 15 --warmup 1 --statement-cap 300 --only $only $*"
}
vmode() {   # fenced|unfenced
    local m=$1
    vrun ids-rows-$m-t10 "ID lists delivered to the client, one row per ID (bm_ids) and as text blocks (bm_ids_text), read as raw bytes from the socket, $m" "B+ rows, B+ text" vertica_ids.sql 1,32 $ROWS
    vrun ids-use-$m-t10 "ID lists used inside the engine: COUNT and SUM of the IDs; the Q8 audience joined to the profile table, $m" "B+ sum, B+ join" vertica_ids.sql 1,32 $USE
    $RV --run=ids-save-setup-$m --purpose="target tables of the save tests created anew" --scale="none" --path="bench/vertica_idtests.sql" -- vsql -X -q -v ON_ERROR_STOP=1 -f bench/vertica_idtests.sql
    vrun ids-save-$m-t10 "the Q8 audience kept in the database: as a set (bm_eval rows) and as a table of IDs (bm_ids), 1 client, $m" "B+ save set, B+ save ids" vertica_ids.sql 1 $SAVE
    vsql -X -A -t -q -c "SELECT 'saved: set_rows=' || (SELECT COUNT(*) FROM bitmap_bench.saved_set) || ' id_rows=' || (SELECT COUNT(*) FROM bitmap_bench.saved_ids) || ' distinct_ids=' || (SELECT COUNT(DISTINCT entity_id) FROM bitmap_bench.saved_ids)"
}
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 14 stopped"; echo ALL_DONE; exit 1; }
cp bench/chains/status.sh $REC/status.sh

# ---- Vertica, fenced (the deployed default) -----------------------------------------------------
vmode fenced
# the live index: tables, load, projections built from the stored rows (the build time), queries
$RV --run=live-create --purpose="live index: schema bitmap_live, tag and event tables (no projection yet)" --scale="none" --path="scripts/live_index.sh" -- bash -c "scripts/live_index.sh drop; scripts/live_index.sh create --tables-only"
$RV --run=live-load-t10 --purpose="live index: tag rows of the person families and the events loaded (plain load, no projection yet)" --scale="tenant 10" --path="scripts/live_index.sh load" -- scripts/live_index.sh load --tenant=10 --watermark="2026-11-01 00:00:00"
$RV --run=live-projections-fenced-t10 --purpose="live index: the two live aggregate projections created and built from the stored rows (the index build), fenced" --scale="tenant 10" --path="scripts/live_index.sh projections" -- scripts/live_index.sh projections
vrun live-headline-fenced-t10 "queries on the live projection (audience count, facets, ID rows), 1 client, fenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1 $LIVE_H --var index=bitmap_live.bitmap_index
vrun live-daily-fenced-t10 "daily distinct users from the live daily projection, fenced" "L" vertica_live.sql 1,32 q2.daily.L

# ---- Vertica, unfenced --------------------------------------------------------------------------
$RV --run=deploy-unfenced-5 --purpose="library redeployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
vmode unfenced
vrun live-headline-unfenced-t10 "queries on the live projection (audience count, facets, ID rows), unfenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1,32 $LIVE_H --var index=bitmap_live.bitmap_index
vrun live-ids-unfenced-t10 "ID lists from the live projection (text blocks, used inside the engine, joined), unfenced" "B+ on bitmap_live.bitmap_index" vertica_ids.sql 1,32 $LIVE_I --var index=bitmap_live.bitmap_index
vrun live-daily-unfenced-t10 "daily distinct users from the live daily projection, unfenced" "L" vertica_live.sql 1,32 q2.daily.L
bench/live_append.sh batch --tenant=10 --residue=6 --export=$EXP/batch_tag.tsv
$RV --run=live-append-under-load-unfenced-t10 --purpose="live index under load: 32 clients query the live projection (audience count 4, facets 2) for 300 s; at 60 s about 2 M new tag rows (1 % of the people, every chunk, 140 topics) are appended; unfenced" --scale="tenant 10" --path="B+ on bitmap_live.bitmap_index + bench/live_append.sh append" -- bash -c "$D mixed --client socket --workload bench/workloads/vertica.sql --var tenant=10 --var index=bitmap_live.bitmap_index --out \$BENCH_RUN_DIR/driver --clients 32 --duration 300 --warmup-s 30 --statement-cap 300 --only $LIVE_MIX --weights q1.count.Bplus=4,q3.Bplus=2 --expect $VCHECK --background 'bench/live_append.sh append --tenant=10' --background-at 60"
vrun live-headline-after-append-unfenced-t10 "queries on the live projection after the append (sets loaded in two pieces are merged when read), unfenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1,32 $LIVE_H --var index=bitmap_live.bitmap_index
$RV --run=live-storage-t10 --purpose="live index: containers, rows and bytes after the appends" --scale="tenant 10" --path="scripts/live_index.sh status" -- scripts/live_index.sh status
$RV --run=deploy-fenced-5 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
$RV --run=live-append-idle-fenced-t10 --purpose="live index: about 2 M more tag rows appended, idle, fenced" --scale="tenant 10" --path="bench/live_append.sh" -- bash -c "bench/live_append.sh batch --tenant=10 --residue=5 && bench/live_append.sh append --tenant=10 && scripts/live_index.sh status"
VROWS=$(ls -d $REC/vertica/*_ids-rows-fenced-t10 | sort | tail -1)/driver/check.csv
VUSE=$(ls -d $REC/vertica/*_ids-use-fenced-t10 | sort | tail -1)/driver/check.csv

# ---- ClickHouse ---------------------------------------------------------------------------------
bench/limits.sh halt
bench/limits.sh start --engine=clickhouse | tail -3
bench/limits.sh status --engine=clickhouse --check | tail -1 || { echo "ClickHouse limits not in place: chain 14 stopped"; bench/limits.sh halt --engine=clickhouse; bench/limits.sh start | tail -2; echo ALL_DONE; exit 1; }
crun() {   # NAME PURPOSE PATH WORKLOAD CLIENTS ONLY [driver options]
    local name=$1 purpose=$2 path=$3 wl=$4 clients=$5 only=$6; shift 6
    $RC --run="$name" --purpose="$purpose" --scale="tenant 10" --path="$path" -- bash -c "$D run --workload bench/workloads/$wl --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients $clients --iterations 15 --warmup 1 --statement-cap 300 --only $only $*"
}
crun ids-rows-t10 "ClickHouse: ID lists delivered to the client, one row per ID, bitmaps" "C rows" clickhouse_ids.sql 1,32 q1.ids.C,q4.C,q8.C --expect $VROWS
crun ids-use-t10 "ClickHouse: ID lists used inside the engine (count and sum; the Q8 audience joined to the profile table, two forms), bitmaps" "C sum, C join" clickhouse_ids.sql 1,32 q1.ids.sum.C,q4.sum.C,q8.sum.C,q8.join.C,q8.join.Cin --expect $VUSE
clickhouse-client --host ::1 --multiquery < bench/engines/clickhouse/idtests.sql
crun ids-save-t10 "ClickHouse: the Q8 audience kept in the database: as a set (one groupBitmap state) and as a table of IDs, 1 client" "C save set, C save ids" clickhouse_ids.sql 1 q8.save.set.C,q8.save.ids.C
clickhouse-client --host ::1 --query "SELECT 'saved: set_rows=' || toString((SELECT count() FROM xbench.saved_set)) || ' id_rows=' || toString((SELECT count() FROM xbench.saved_ids)) || ' distinct_ids=' || toString((SELECT uniqExact(entity_id) FROM xbench.saved_ids))"
$RC --run=live-create --purpose="ClickHouse live sets: tag table, AggregatingMergeTree table of groupBitmap states, materialized view" --scale="none" --path="bench/ch.sh live-create" -- bench/ch.sh live-create
$RC --run=live-load-t10 --purpose="ClickHouse live sets: tag rows of the person families inserted, the materialized view builds the sets; then OPTIMIZE FINAL" --scale="tenant 10" --path="bench/ch.sh live-load" -- bench/ch.sh live-load --tenant=10
crun live-headline-t10 "ClickHouse: queries on the sets kept by the materialized view (audience count, facets, ID rows)" "C on xbench.live_bitmap" clickhouse.sql 1,32 q1.count.C,q3.C,q8.C --var ptable=xbench.live_bitmap --expect $VCHECK
bench/ch.sh live-batch --tenant=10
$RC --run=live-append-under-load-t10 --purpose="ClickHouse live sets under load: 32 clients query the sets kept by the materialized view (audience count 4, facets 2) for 300 s; at 60 s the same 2 M tag rows are appended" --scale="tenant 10" --path="C on xbench.live_bitmap + bench/ch.sh live-append" -- bash -c "$D mixed --workload bench/workloads/clickhouse.sql --var tenant=10 --var ptable=xbench.live_bitmap --out \$BENCH_RUN_DIR/driver --clients 32 --duration 300 --warmup-s 30 --statement-cap 300 --only q1.count.C,q3.C --weights q1.count.C=4,q3.C=2 --expect $VCHECK --background 'bench/ch.sh live-append --tenant=10' --background-at 60"
crun live-headline-after-append-t10 "ClickHouse: queries on the sets kept by the materialized view after the append" "C on xbench.live_bitmap" clickhouse.sql 1,32 q1.count.C,q3.C,q8.C --var ptable=xbench.live_bitmap --expect $VCHECK
$RC --run=live-storage-t10 --purpose="ClickHouse storage with the tag table and the live sets" --scale="tenant 10" --path="bench/ch.sh storage" -- bench/ch.sh storage
bench/limits.sh halt --engine=clickhouse
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1
echo ALL_DONE

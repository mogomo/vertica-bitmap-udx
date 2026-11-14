#!/usr/bin/env bash
# Chain 15: everything Vertica again with the final library, read through the socket client.
# Changes since chain 14: the word loops of the set library are compiled for AVX2 / POPCNT as well
# and chosen at load time (the baseline x86-64 build had no hardware population count); the live
# tables carry chunk (and day) as DEFAULT columns, so that the live projections partition by table
# columns only and can be built from stored rows as well as maintained by any kind of load.
# Runs: the headline queries, the ID-list tests and the live index, fenced and unfenced.
# ClickHouse is not run again: nothing on its side changed (chains 14, 14b, 14c).
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5c"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
XROWS=$(ls -d $REC/vertica/*_ids-rows-fenced-t10 | sort | head -1)/driver/check.csv
XUSE=$(ls -d $REC/vertica/*_ids-use-fenced-t10 | sort | head -1)/driver/check.csv
D="python3 bench/driver.py"
HEAD=q1.count.Bplus,q1.ids.Bplus,q2.daily.B,q3.Bplus,q4.Bplus,q7.Bj,q7.Bplus,q8.Bplus
ROWS=q1.ids.Bplus,q4.Bplus,q8.Bplus,q1.ids.text.Bplus,q4.text.Bplus,q8.text.Bplus
USE=q1.ids.sum.Bplus,q4.sum.Bplus,q8.sum.Bplus,q8.join.Bplus
SAVE=q8.save.set.Bplus,q8.save.ids.Bplus
LIVE_H=q1.count.Bplus,q3.Bplus,q8.Bplus
LIVE_MIX=q1.count.Bplus,q3.Bplus
vrun() {   # NAME PURPOSE PATH WORKLOAD CLIENTS ONLY [driver options]
    local name=$1 purpose=$2 path=$3 wl=$4 clients=$5 only=$6; shift 6
    $RV --run="$name" --purpose="$purpose" --scale="tenant 10" --path="$path" -- bash -c "$D run --client socket --workload bench/workloads/$wl --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients $clients --iterations 15 --warmup 1 --statement-cap 300 --only $only $*"
}
vmode() {   # fenced|unfenced
    local m=$1
    vrun final-headline-$m-t10 "headline queries with the final library (chunk-ordered projection), read from the socket, $m" "B, B+" vertica.sql 1,32 $HEAD --expect $VCHECK --skip-oracles
    vrun final-ids-rows-$m-t10 "ID lists delivered to the client, one row per ID (bm_ids) and as text blocks (bm_ids_text), final library, $m" "B+ rows, B+ text" vertica_ids.sql 1,32 $ROWS --expect $XROWS --skip-oracles
    vrun final-ids-use-$m-t10 "ID lists used inside the engine (count and sum; the Q8 audience joined to the profile table), final library, $m" "B+ sum, B+ join" vertica_ids.sql 1,32 $USE --expect $XUSE --skip-oracles
    $RV --run=final-ids-save-setup-$m --purpose="target tables of the save tests created anew" --scale="none" --path="bench/vertica_idtests.sql" -- vsql -X -q -v ON_ERROR_STOP=1 -f bench/vertica_idtests.sql
    vrun final-ids-save-$m-t10 "the Q8 audience kept in the database: as a set (bm_eval rows) and as a table of IDs (bm_ids), 1 client, final library, $m" "B+ save set, B+ save ids" vertica_ids.sql 1 $SAVE
    vsql -X -A -t -q -c "SELECT 'saved: set_rows=' || (SELECT COUNT(*) FROM bitmap_bench.saved_set) || ' id_rows=' || (SELECT COUNT(*) FROM bitmap_bench.saved_ids) || ' distinct_ids=' || (SELECT COUNT(DISTINCT entity_id) FROM bitmap_bench.saved_ids)"
}
bench/limits.sh status --check | tail -1 || { bench/limits.sh start | tail -2; bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 15 stopped"; echo ALL_DONE; exit 1; }; }
cp bench/chains/status.sh $REC/status.sh
$RV --run=deploy-fenced-7 --purpose="final library deployed fenced" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes

# ---- fenced -------------------------------------------------------------------------------------
vmode fenced
# live index, built from rows already stored (the build cost), then dropped
$RV --run=live2-create-tables --purpose="live index: schema bitmap_live created anew, tables only" --scale="none" --path="scripts/live_index.sh" -- bash -c "scripts/live_index.sh drop; scripts/live_index.sh create --tables-only"
$RV --run=live2-load-plain-t10 --purpose="live index: tag rows and events loaded, no projection yet (plain load)" --scale="tenant 10" --path="scripts/live_index.sh load" -- scripts/live_index.sh load --tenant=10 --watermark="2026-11-01 00:00:00"
$RV --run=live2-projections-fenced-t10 --purpose="live index: both live projections created and built from the stored rows (the index build), fenced" --scale="tenant 10" --path="scripts/live_index.sh projections" -- scripts/live_index.sh projections
# live index the usual way: projections first, the load maintains them
$RV --run=live2-create --purpose="live index: schema bitmap_live created anew, tables and both live projections (empty)" --scale="none" --path="scripts/live_index.sh create" -- bash -c "scripts/live_index.sh drop; scripts/live_index.sh create"
$RV --run=live2-load-maintained-fenced-t10 --purpose="live index: tag rows and events loaded with the live projections in place (the load builds the sets), fenced" --scale="tenant 10" --path="scripts/live_index.sh load" -- scripts/live_index.sh load --tenant=10 --watermark="2026-11-01 00:00:00"
vrun live2-headline-fenced-t10 "queries on the live projection (audience count, facets, ID rows), 1 client, fenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1 $LIVE_H --var index=bitmap_live.bitmap_index --expect $VCHECK --skip-oracles
vrun live2-daily-fenced-t10 "daily distinct users from the live daily projection, fenced" "L" vertica_live.sql 1,32 q2.daily.L

# ---- unfenced -----------------------------------------------------------------------------------
$RV --run=deploy-unfenced-7 --purpose="final library deployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
vmode unfenced
vrun live2-headline-unfenced-t10 "queries on the live projection (audience count, facets, ID rows), unfenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1,32 $LIVE_H --var index=bitmap_live.bitmap_index --expect $VCHECK --skip-oracles
vrun live2-ids-unfenced-t10 "ID lists from the live projection as text blocks, unfenced" "B+ on bitmap_live.bitmap_index" vertica_ids.sql 1,32 q1.ids.text.Bplus,q8.text.Bplus --var index=bitmap_live.bitmap_index --expect $XROWS --skip-oracles
vrun live2-use-unfenced-t10 "ID lists from the live projection used inside the engine and joined to the profile table, unfenced" "B+ on bitmap_live.bitmap_index" vertica_ids.sql 1,32 q8.sum.Bplus,q8.join.Bplus --var index=bitmap_live.bitmap_index --expect $XUSE --skip-oracles
vrun live2-daily-unfenced-t10 "daily distinct users from the live daily projection, unfenced" "L" vertica_live.sql 1,32 q2.daily.L
bench/live_append.sh batch --tenant=10 --residue=6
$RV --run=live2-append-under-load-unfenced-t10 --purpose="live index under load: 32 clients query the live projection (audience count 4, facets 2) for 300 s; at 60 s about 2 M new tag rows (1 % of the people, every chunk, 20 topics; the rows ClickHouse appended in chain 14) are appended; unfenced" --scale="tenant 10" --path="B+ on bitmap_live.bitmap_index + bench/live_append.sh append" -- bash -c "$D mixed --client socket --workload bench/workloads/vertica.sql --var tenant=10 --var index=bitmap_live.bitmap_index --out \$BENCH_RUN_DIR/driver --clients 32 --duration 300 --warmup-s 30 --statement-cap 300 --only $LIVE_MIX --weights q1.count.Bplus=4,q3.Bplus=2 --expect $VCHECK --skip-oracles --background 'bench/live_append.sh append --tenant=10' --background-at 60"
vrun live2-headline-after-append-unfenced-t10 "queries on the live projection after the append (sets loaded in two pieces are merged when read), unfenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1,32 $LIVE_H --var index=bitmap_live.bitmap_index --expect $VCHECK --skip-oracles
$RV --run=live2-storage-t10 --purpose="live index: containers, rows and bytes after the append" --scale="tenant 10" --path="scripts/live_index.sh status" -- scripts/live_index.sh status
$RV --run=deploy-fenced-8 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
$RV --run=live2-append-idle-fenced-t10 --purpose="live index: about 2 M more tag rows appended, idle, fenced" --scale="tenant 10" --path="bench/live_append.sh" -- bash -c "bench/live_append.sh batch --tenant=10 --residue=5 && bench/live_append.sh append --tenant=10 && scripts/live_index.sh status"
bench/limits.sh status --check | tail -1
echo ALL_DONE

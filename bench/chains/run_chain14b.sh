#!/usr/bin/env bash
# Chain 14b: the live index again. In chain 14 the tag projection of the first table design was
# not built, so the live queries of chain 14 found no usable projection and are recorded as
# invalid. Here the projections are created on the empty tables and the load maintains them, which
# is how a live index is used anyway. (Superseded by chain 15, which uses the second table design:
# the chunk as a column of the table.)
set -u
until grep -q ALL_DONE ~/bitmap_record/last_run14.log; do sleep 30; done
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5c"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
D="python3 bench/driver.py"
LIVE_H=q1.count.Bplus,q3.Bplus,q8.Bplus
LIVE_MIX=q1.count.Bplus,q3.Bplus
LIVE_I=q1.ids.text.Bplus,q8.text.Bplus,q8.sum.Bplus,q8.join.Bplus
vrun() {   # NAME PURPOSE PATH WORKLOAD CLIENTS ONLY [driver options]
    local name=$1 purpose=$2 path=$3 wl=$4 clients=$5 only=$6; shift 6
    $RV --run="$name" --purpose="$purpose" --scale="tenant 10" --path="$path" -- bash -c "$D run --client socket --workload bench/workloads/$wl --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients $clients --iterations 15 --warmup 1 --statement-cap 300 --only $only $*"
}
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 14b stopped"; echo ALL_DONE; exit 1; }
$RV --run=live-create-2 --purpose="live index: schema bitmap_live created anew, tables and both live projections (empty)" --scale="none" --path="scripts/live_index.sh create" -- bash -c "scripts/live_index.sh drop; scripts/live_index.sh create"
$RV --run=live-load-maintained-fenced-t10 --purpose="live index: tag rows and events loaded with the live projections in place (the load builds the sets), fenced" --scale="tenant 10" --path="scripts/live_index.sh load" -- scripts/live_index.sh load --tenant=10 --watermark="2026-11-01 00:00:00"
vrun live-headline-fenced-t10 "queries on the live projection (audience count, facets, ID rows), 1 client, fenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1 $LIVE_H --var index=bitmap_live.bitmap_index
vrun live-daily-fenced-t10 "daily distinct users from the live daily projection, fenced" "L" vertica_live.sql 1,32 q2.daily.L
$RV --run=deploy-unfenced-6 --purpose="library redeployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
vrun live-headline-unfenced-t10 "queries on the live projection (audience count, facets, ID rows), unfenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1,32 $LIVE_H --var index=bitmap_live.bitmap_index
vrun live-ids-unfenced-t10 "ID lists from the live projection (text blocks, used inside the engine, joined), unfenced" "B+ on bitmap_live.bitmap_index" vertica_ids.sql 1,32 $LIVE_I --var index=bitmap_live.bitmap_index
vrun live-daily-unfenced-t10 "daily distinct users from the live daily projection, unfenced" "L" vertica_live.sql 1,32 q2.daily.L
bench/live_append.sh batch --tenant=10 --residue=6
$RV --run=live-append-under-load-unfenced-t10 --purpose="live index under load: 32 clients query the live projection (audience count 4, facets 2) for 300 s; at 60 s about 2 M new tag rows (1 % of the people, every chunk, 20 topics; the rows ClickHouse appended in chain 14) are appended; unfenced" --scale="tenant 10" --path="B+ on bitmap_live.bitmap_index + bench/live_append.sh append" -- bash -c "$D mixed --client socket --workload bench/workloads/vertica.sql --var tenant=10 --var index=bitmap_live.bitmap_index --out \$BENCH_RUN_DIR/driver --clients 32 --duration 300 --warmup-s 30 --statement-cap 300 --only $LIVE_MIX --weights q1.count.Bplus=4,q3.Bplus=2 --expect $VCHECK --background 'bench/live_append.sh append --tenant=10' --background-at 60"
vrun live-headline-after-append-unfenced-t10 "queries on the live projection after the append (sets loaded in two pieces are merged when read), unfenced" "B+ on bitmap_live.bitmap_index" vertica.sql 1,32 $LIVE_H --var index=bitmap_live.bitmap_index
$RV --run=live-storage-t10 --purpose="live index: containers, rows and bytes after the append" --scale="tenant 10" --path="scripts/live_index.sh status" -- scripts/live_index.sh status
$RV --run=deploy-fenced-6 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
$RV --run=live-append-idle-fenced-t10 --purpose="live index: about 2 M more tag rows appended, idle, fenced" --scale="tenant 10" --path="bench/live_append.sh" -- bash -c "bench/live_append.sh batch --tenant=10 --residue=5 && bench/live_append.sh append --tenant=10 && scripts/live_index.sh status"

# ---- ClickHouse: the delivered ID lists again, read the same way --------------------------------
# In chain 14 the driver split every ClickHouse answer into rows inside the measuring thread, right
# after stopping the clock, while it kept Vertica's answers as raw bytes until the block was over.
# With 32 threads on two client CPUs that splitting delays the other threads' reads. The driver now
# keeps ClickHouse's answers raw as well (TsvResult); this run replaces chain 14's ids-rows-t10.
RC="bench/record.sh --area=clickhouse --engine=clickhouse --milestone=M5c"
VROWS=$(ls -d $REC/vertica/*_ids-rows-fenced-t10 | sort | tail -1)/driver/check.csv
bench/limits.sh halt
bench/limits.sh start --engine=clickhouse | tail -3
if bench/limits.sh status --engine=clickhouse --check | tail -1; then
    $RC --run=ids-rows-raw-t10 --purpose="ClickHouse: ID lists delivered to the client, one row per ID, bitmaps; answers kept as raw bytes until the block is over, as for Vertica (replaces ids-rows-t10)" --scale="tenant 10" --path="C rows" -- bash -c "$D run --workload bench/workloads/clickhouse_ids.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only q1.ids.C,q4.C,q8.C --expect $VROWS"
else
    echo "ClickHouse limits not in place: rerun skipped"
fi
bench/limits.sh halt --engine=clickhouse
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1
echo ALL_DONE

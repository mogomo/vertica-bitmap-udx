#!/usr/bin/env bash
# Chain 19: the three tests ClickHouse led, measured again with what the library gained for them.
#  1. One row per ID sent to a client: bm_ids with text = true (the ID formatted by the function,
#     the same bytes on the wire) next to the INT form, in the same run; Q1, Q4 and Q8 lists.
#  2. An ID list joined to another table row by row: the audience pinned in memory (bm_pin) and
#     every profile row tested on the scan threads (bm_member), next to the semi-join with the
#     ID list, in the same run. 10 M people at 1 and 32 clients, fenced and unfenced; 100 M people
#     at 1 client, unfenced.
#  3. Building the sets: scripts/snapshot.sh build --aggregate (bm_build_agg, GROUP BY predicate
#     and chunk, one statement per SELECT of each family definition) in a pool that gives one
#     build the memory for one bitset per group. The payload columns take ZSTD_FAST_COMP for new
#     storage. Person sets with daily sets, device sets, at 10 M; person sets with daily sets at
#     100 M. The new 10 M snapshot is queried as it was written (one container per statement).
#     Every snapshot built here is validated by the lifecycle and discarded afterwards: the
#     published snapshots stay as they were measured.
#  ClickHouse again in the same chain: the delivered lists, the join, and its own build (snapshot 2
#  from source snapshot 1, removed afterwards).
# Every statement is capped.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5d"
RC="bench/record.sh --area=clickhouse --engine=clickhouse --milestone=M5d"
REC=~/bitmap_record
XROWS=$(ls -d $REC/vertica/*_ids-rows-fenced-t10 | sort | head -1)/driver/check.csv
XUSE=$(ls -d $REC/vertica/*_ids-use-fenced-t10 | sort | head -1)/driver/check.csv
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
T20CHECK=$(ls -d $REC/vertica/*_latency-bitmap-c1c32-t20b | sort | tail -1)/driver/check.csv
T20AGG=$(ls -d $REC/vertica/*_check-agg-t20 | sort | tail -1)/driver/check.csv
D="python3 bench/driver.py"
V="vsql -X -A -t -q -v ON_ERROR_STOP=1"
ROWS=q8.Bplus,q8.rowtext.Bplus,q1.ids.Bplus,q1.ids.rowtext.Bplus,q4.Bplus,q4.rowtext.Bplus
JOIN=q8.join.Bplus,q8.join.Bpin
vrun() {   # NAME PURPOSE PATH WORKLOAD TENANT CLIENTS ONLY [driver options]
    local name=$1 purpose=$2 path=$3 wl=$4 tenant=$5 clients=$6 only=$7; shift 7
    $RV --run="$name" --purpose="$purpose" --scale="tenant $tenant" --path="$path" -- bash -c "$D run --client socket --workload bench/workloads/$wl --var tenant=$tenant --out \$BENCH_RUN_DIR/driver --clients $clients --iterations 15 --warmup 1 --statement-cap 300 --only $only $*"
}
qmode() {   # fenced|unfenced: delivered rows and the join at 10 M
    local m=$1
    vrun rows-text-$m-t10 "ID lists sent to the client one row per ID: the INT column (bm_ids) and the ID formatted by the function (bm_ids text = true), same run, $m" "B+ rows, B+ rowtext" vertica_ids.sql 10 1,32 $ROWS --expect $XROWS --skip-oracles
    vrun join-pin-$m-t10 "the Q8 audience joined to the 10 M profile rows: semi-join with the ID list (q8.join.Bplus) and pinned set tested on the scan threads (bm_pin + bm_member, q8.join.Bpin), same run, $m" "B+ join, B+ pin" vertica_ids.sql 10 1,32 $JOIN --expect $XUSE --skip-oracles
}
newest() { $V -c "SELECT MAX(snapshot_id) FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $1 AND domain = '$2'"; }

bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 19 stopped"; echo ALL_DONE; exit 1; }
cp bench/chains/status.sh $REC/status.sh

# ---- 1 and 2: delivered rows and the join, fenced then unfenced ---------------------------------
$RV --run=deploy-fenced-14 --purpose="library with pinned sets, text rows and the aggregate builder deployed fenced (no aggregates)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
qmode fenced
$RV --run=deploy-unfenced-14 --purpose="the same library deployed unfenced (with bm_build_agg and bm_union_agg)" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
qmode unfenced
vrun rows-text-unfenced-t20 "100 M people, 1 client, unfenced: the 5.3 M IDs of the Q8 audience as INT rows and as text rows" "B+ rows, B+ rowtext" vertica_ids.sql 20 1 q8.Bplus,q8.rowtext.Bplus --expect $T20CHECK --skip-oracles
vrun join-pin-unfenced-t20 "100 M people, 1 client, unfenced: the Q8 audience joined to the 100 M profile rows as a semi-join and through the pinned set" "B+ join, B+ pin" vertica_ids.sql 20 1 $JOIN --expect $T20AGG --skip-oracles

# ---- 3: the build ------------------------------------------------------------------------------
$V -c "CREATE RESOURCE POOL bitmap_build MEMORYSIZE '0%' MAXMEMORYSIZE '40G' PLANNEDCONCURRENCY 1" 2>&1 | grep -v "already exists" || true
$V <<'SQL'
ALTER TABLE bitmap_demo.bitmap_index ALTER COLUMN payload ENCODING ZSTD_FAST_COMP PROJECTIONS (bitmap_demo.bitmap_index_super, bitmap_demo.bitmap_index_by_chunk);
ALTER TABLE bitmap_demo.daily_bitmap ALTER COLUMN payload ENCODING ZSTD_FAST_COMP PROJECTIONS (bitmap_demo.daily_bitmap_super);
SQL
BUILD="build --source-snapshot=1 --snapshot=next --aggregate --pool=bitmap_build"
$RV --run=build-agg-person-t10 --purpose="lifecycle build of a new person snapshot of tenant 10 with the aggregate builder (7 families incl. the bit slices of the age, 554 sets; daily sets), pool bitmap_build, ZSTD_FAST_COMP payload storage, both index projections; validated" --scale="tenant 10" --path="snapshot.sh build --aggregate" -- scripts/snapshot.sh $BUILD --tenant=10 --domain=person --watermark="2026-11-01 00:00:00" --daily
$RV --run=build-agg-device-t10 --purpose="lifecycle build of a new device snapshot of tenant 10 with the aggregate builder (4 families, 24 sets); validated" --scale="tenant 10" --path="snapshot.sh build --aggregate" -- scripts/snapshot.sh $BUILD --tenant=10 --domain=device --watermark="2026-11-01 12:00:00"
P10=$(newest 10 person); D10=$(newest 10 device)
echo "new snapshots of tenant 10: person $P10, device $D10"
$RV --run=build-agg-storage-t10 --purpose="storage containers of the index after the aggregate build (one per statement)" --scale="tenant 10" --path="v_monitor.storage_containers" -- $V -c "SELECT 'containers: projection=' || projection_name || ' containers=' || COUNT(*) || ' rows=' || SUM(total_row_count) || ' mb=' || ROUND(SUM(used_bytes) / 1e6, 1) FROM v_monitor.storage_containers WHERE schema_name = 'bitmap_demo' AND projection_name ILIKE ANY ('bitmap_index%', 'daily_bitmap%') GROUP BY projection_name ORDER BY 1"
if [ "$P10" != 1 ]; then
    vrun headline-agg-snapshot-unfenced-t10 "audience count, facets and the Q8 ID list on the snapshot the aggregate builder wrote (person snapshot $P10, as written: one storage container per statement), unfenced" "B+ on the new snapshot" vertica.sql 10 1,32 q1.count.Bplus,q3.Bplus,q8.Bplus --var psnap=$P10 --expect $VCHECK --skip-oracles
    $RV --run=build-agg-discard-t10 --purpose="the snapshots built by the aggregate builder discarded (never published)" --scale="tenant 10" --path="snapshot.sh discard" -- bash -c "scripts/snapshot.sh discard --tenant=10 --domain=person --snapshot=$P10 && scripts/snapshot.sh discard --tenant=10 --domain=device --snapshot=$D10"
fi
$RV --run=build-agg-person-t20 --purpose="lifecycle build of a new person snapshot of tenant 20 (100 M people, 2 billion interest rows, 1 billion events) with the aggregate builder, pool bitmap_build; validated" --scale="tenant 20" --path="snapshot.sh build --aggregate" -- scripts/snapshot.sh $BUILD --tenant=20 --domain=person --watermark="2026-11-01 00:00:00" --daily
P20=$(newest 20 person)
[ "$P20" = 1 ] || $RV --run=build-agg-discard-t20 --purpose="the 100 M snapshot built by the aggregate builder discarded (never published)" --scale="tenant 20" --path="snapshot.sh discard" -- scripts/snapshot.sh discard --tenant=20 --domain=person --snapshot=$P20
$RV --run=deploy-fenced-15 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes

# ---- ClickHouse again: delivered lists, the join, its build --------------------------------------
bench/limits.sh halt
bench/limits.sh start --engine=clickhouse | tail -3
if bench/limits.sh status --engine=clickhouse --check | tail -1; then
    crun() {   # NAME PURPOSE PATH CLIENTS ONLY EXPECT
        $RC --run="$1" --purpose="$2" --scale="tenant 10" --path="$3" -- bash -c "$D run --workload bench/workloads/clickhouse_ids.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients $4 --iterations 15 --warmup 1 --statement-cap 300 --only $5 --expect $6"
    }
    crun ids-rows2-t10 "ClickHouse again: ID lists delivered to the client, one row per ID, bitmaps (as run 154)" "C rows" 1,32 q1.ids.C,q4.C,q8.C $XROWS
    crun ids-join2-t10 "ClickHouse again: the Q8 audience joined to the profile table, both forms (as run 133)" "C join" 1,32 q8.join.C,q8.join.Cin $XUSE
    $RC --run=build2-t10 --purpose="ClickHouse again: its build of the person, daily and device sets as snapshot 2 from source snapshot 1 (as run 71)" --scale="tenant 10" --path="bench/ch.sh build" -- bench/ch.sh build --tenant=10 --snapshot=2 --source-snapshot=1
    $RC --run=build-bits2-t10 --purpose="ClickHouse again: the bit-sliced sets of the age for snapshot 2 (as run 215)" --scale="tenant 10" --path="bench/ch.sh build-bits" -- bench/ch.sh build-bits --tenant=10 --snapshot=2 --source-snapshot=1
    bench/ch.sh drop-snapshot --tenant=10 --snapshot=2
else
    echo "ClickHouse limits not in place: ClickHouse part of chain 19 skipped"
fi
bench/limits.sh halt --engine=clickhouse
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1
echo ALL_DONE

#!/usr/bin/env bash
# Chain 19b: the build again. In chain 19 the aggregate builder wrote the index with one INSERT per
# SELECT of the definitions: eight storage containers for a snapshot, which the queries feel under
# concurrency. It now fills the builder's temporary table and the index receives one INSERT, as with
# the transform; the bit slices of the age are defined as plain SELECTs (sql/families_bitsliced.sql).
#  - person snapshot with daily sets and device snapshot of tenant 10, aggregate builder, unfenced
#  - the new person snapshot queried as written, and the published snapshot in the same run
#  - the transform builder once more, fenced, with what changed for both builders (ZSTD_FAST_COMP
#    payload storage, statistics on the key columns only)
# Every snapshot built here is validated and discarded.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5d"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
D="python3 bench/driver.py"
V="vsql -X -A -t -q -v ON_ERROR_STOP=1"
HEAD=q1.count.Bplus,q3.Bplus,q8.Bplus
newest() { $V -c "SELECT MAX(snapshot_id) FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $1 AND domain = '$2'"; }
vrun() {   # NAME PURPOSE PATH ONLY [driver options]
    local name=$1 purpose=$2 path=$3 only=$4; shift 4
    $RV --run="$name" --purpose="$purpose" --scale="tenant 10" --path="$path" -- bash -c "$D run --client socket --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only $only $*"
}
storage() {
    $RV --run="$1" --purpose="storage containers of the index and the daily sets after the build" --scale="tenant 10" --path="v_monitor.storage_containers" -- $V -c "SELECT 'containers: projection=' || projection_name || ' containers=' || COUNT(*) || ' rows=' || SUM(total_row_count) || ' mb=' || ROUND(SUM(used_bytes) / 1e6, 1)::VARCHAR FROM v_monitor.storage_containers WHERE schema_name = 'bitmap_demo' AND projection_name ILIKE ANY ('bitmap_index%', 'daily_bitmap%') GROUP BY projection_name ORDER BY 1"
}
bench/limits.sh status --check | tail -1 || { bench/limits.sh start | tail -2; bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 19b stopped"; echo ALL_DONE; exit 1; }; }
cp bench/chains/status.sh $REC/status.sh
# the catalog of the benchmark tenants takes the new definition of the bit-slice family (same sets)
for t in 10 20; do
    $V -c "DELETE FROM bitmap_demo.bitmap_family WHERE tenant_id = $t AND domain = 'person' AND family = 'age_bits'; COMMIT" > /dev/null
    $V -v tenant=$t -f sql/families_bitsliced.sql > /dev/null
done
$V -c "CREATE RESOURCE POOL bitmap_build MEMORYSIZE '0%' MAXMEMORYSIZE '40G' PLANNEDCONCURRENCY 1" 2>&1 | grep -v "already exists" || true
BUILD="build --tenant=10 --source-snapshot=1 --snapshot=next"

$RV --run=deploy-unfenced-15 --purpose="library deployed unfenced (aggregate builder through the temporary table)" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
$RV --run=build-agg2-person-t10 --purpose="lifecycle build of a new person snapshot of tenant 10 with the aggregate builder (7 families incl. the bit slices of the age, 554 sets; daily sets), one INSERT into the index, pool bitmap_build, ZSTD_FAST_COMP payload storage, both index projections; validated" --scale="tenant 10" --path="snapshot.sh build --aggregate" -- scripts/snapshot.sh $BUILD --domain=person --watermark="2026-11-01 00:00:00" --daily --aggregate --pool=bitmap_build
$RV --run=build-agg2-device-t10 --purpose="lifecycle build of a new device snapshot of tenant 10 with the aggregate builder (4 families, 24 sets); validated" --scale="tenant 10" --path="snapshot.sh build --aggregate" -- scripts/snapshot.sh $BUILD --domain=device --watermark="2026-11-01 12:00:00" --aggregate --pool=bitmap_build
P10=$(newest 10 person); D10=$(newest 10 device)
echo "new snapshots of tenant 10: person $P10, device $D10"
storage build-agg2-storage-t10
if [ "$P10" != 1 ]; then
    vrun headline-agg2-snapshot-unfenced-t10 "audience count, facets and the Q8 ID list on the snapshot the aggregate builder wrote (person snapshot $P10, as written), unfenced" "B+ on the new snapshot" $HEAD --var psnap=$P10 --expect $VCHECK --skip-oracles
    vrun headline-published-unfenced-t10 "the same three queries on the published snapshot 1 right afterwards, unfenced" "B+" $HEAD --expect $VCHECK --skip-oracles
    $RV --run=build-agg2-discard-t10 --purpose="the snapshots built by the aggregate builder discarded (never published)" --scale="tenant 10" --path="snapshot.sh discard" -- bash -c "scripts/snapshot.sh discard --tenant=10 --domain=person --snapshot=$P10 && scripts/snapshot.sh discard --tenant=10 --domain=device --snapshot=$D10"
fi
$RV --run=deploy-fenced-16 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
$RV --run=build-transform2-fenced-person-t10 --purpose="lifecycle build of a new person snapshot of tenant 10 with the transform builder, fenced, as run 58 but with the bit-slice family (554 sets), ZSTD_FAST_COMP payload storage and statistics on the key columns only; validated" --scale="tenant 10" --path="snapshot.sh build" -- scripts/snapshot.sh $BUILD --domain=person --watermark="2026-11-01 00:00:00" --daily
P10=$(newest 10 person)
[ "$P10" = 1 ] || $RV --run=build-transform2-discard-t10 --purpose="the snapshot built by the transform builder discarded (never published)" --scale="tenant 10" --path="snapshot.sh discard" -- scripts/snapshot.sh discard --tenant=10 --domain=person --snapshot=$P10
bench/limits.sh status --check | tail -1
echo ALL_DONE

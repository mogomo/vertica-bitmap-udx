#!/usr/bin/env bash
# Chain 10: chunk-ordered index projection and the facet form of Q7 (after the ClickHouse comparison).
# Revised 2026-11-13 (before it started): q7.B -> q7.Bj (plain subqueries, the form used at 100 M, see chain
# 8b); at 100 M the answers are checked against the oracle answers of latency-bitmap-c1c32-t20b
# (--expect, --skip-oracles) instead of re-running the native Q7 (35 min) in every run.
# Revised again 2026-11-13 (before it started): every statement is capped (--statement-cap: a statement
# that passes the cap is recorded as a time-out and the run goes on); at 100 M the six queries run at
# 1 client and only the interactive audience count at 32 clients (32 simultaneous facet or overlap
# queries over 100 M people are a stress test, measured once in chain 8b, not a usage pattern).
set -u
until grep -q ALL_DONE ~/bitmap_record/last_run9.log; do sleep 60; done
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
R="bench/record.sh --area=vertica --milestone=M5b"
SET=q1.count.Bplus,q1.ids.Bplus,q3.Bplus,q7.Bj,q7.Bplus,q8.Bplus
T20CHECK=$(ls -d ~/bitmap_record/vertica/*_latency-bitmap-c1c32-t20b 2>/dev/null | tail -n 1)/driver/check.csv
CAP=300   # seconds per statement (the slowest bitmap statement so far: 18 s at 1 client, 100 M)
lat() {   # NAME TENANT CLIENTS PURPOSE [QUERIES]
    local extra="" set=${5:-$SET}
    if [ "$2" = 20 ]; then
        [ -s "$T20CHECK" ] || { echo "chain 10: no check.csv of latency-bitmap-c1c32-t20b: $1 skipped"; return 0; }
        extra="--expect $T20CHECK --skip-oracles"
    fi
    $R --run=$1 --purpose="$4" --scale="tenant $2" --path="B, B+ ($set)" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=$2 --out \$BENCH_RUN_DIR/driver --clients $3 --iterations 15 --warmup 1 --statement-cap $CAP --only $set $extra"
}
bench/limits.sh status --check | tail -1
lat latency-bplus-before-t10 10 1,32 "bitmap paths before the chunk-ordered projection, fenced (q7.Bplus new: facet form)"
$R --run=projection-bychunk --purpose="create and refresh bitmap_index_by_chunk (sorted by tenant, snapshot, domain, chunk, predicate) for tenants 10 and 20" --scale="tenants 10 + 20" --path="bench/vertica_projection_bychunk.sql" -- bash -c "vsql -X -v ON_ERROR_STOP=1 -e -f bench/vertica_projection_bychunk.sql"
lat latency-bplus-bychunk-t10 10 1,32 "bitmap paths with the chunk-ordered projection, fenced"
lat latency-bplus-bychunk-t20 20 1 "bitmap paths at 100 M with the chunk-ordered projection, fenced, 1 client"
lat latency-bplus-bychunk-c32-t20 20 32 "audience count at 100 M with the chunk-ordered projection, fenced, 32 clients" q1.count.Bplus
$R --run=deploy-unfenced-2 --purpose="library redeployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
lat latency-bplus-bychunk-unfenced-t10 10 1,32 "bitmap paths with the chunk-ordered projection, unfenced"
lat latency-bplus-bychunk-unfenced-t20 20 1 "bitmap paths at 100 M with the chunk-ordered projection, unfenced, 1 client"
lat latency-bplus-bychunk-unfenced-c32-t20 20 32 "audience count at 100 M with the chunk-ordered projection, unfenced, 32 clients" q1.count.Bplus
$R --run=deploy-fenced-2 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
$R --run=storage-bychunk --purpose="storage with the second index projection" --scale="tenants 10 + 20" --path="projection_storage" -- bench/storage.sh
echo ALL_DONE

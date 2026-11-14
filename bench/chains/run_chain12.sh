#!/usr/bin/env bash
# Chain 12: the two headline queries that chain 10 did not repeat (Q2 daily distinct users, Q4 hot
# devices), measured with the chunk-ordered projection in place, fenced and unfenced, so that the
# article's 10 M table has every bitmap number from the same database state (chains 10 and 12).
set -u
until grep -q ALL_DONE ~/bitmap_record/last_run11.log; do sleep 60; done
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
R="bench/record.sh --area=vertica --milestone=M5b"
SET=q2.daily.B,q4.Bplus
lat() {   # NAME PURPOSE
    $R --run=$1 --purpose="$2" --scale="tenant 10" --path="B, B+ ($SET)" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only $SET"
}
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 12 stopped"; echo ALL_DONE; exit 1; }
lat latency-q2q4-bychunk-t10 "Q2 daily and Q4 with the chunk-ordered projection in place, fenced"
$R --run=deploy-unfenced-4 --purpose="library redeployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
lat latency-q2q4-bychunk-unfenced-t10 "Q2 daily and Q4 with the chunk-ordered projection in place, unfenced"
$R --run=deploy-fenced-4 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
echo ALL_DONE

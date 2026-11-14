#!/usr/bin/env bash
# Chain 11: refresh under load again (Vertica with the chunk-ordered projection and q7.Bplus, fenced and
# unfenced; 600 s windows), then ClickHouse: latency rerun (driver reconnect fix) and refresh under load.
# Revised 2026-11-13 (before it started): every statement is capped (--statement-cap).
set -u
until grep -q ALL_DONE ~/bitmap_record/last_run10.log; do sleep 60; done
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5b"
RC="bench/record.sh --area=clickhouse --engine=clickhouse --milestone=M5b"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
MIX_V=q1.count.Bplus,q2.daily.B,q3.Bplus,q4.Bplus,q7.Bplus,q8.Bplus
W_V=q1.count.Bplus=4,q2.daily.B=2,q3.Bplus=2,q4.Bplus=1,q7.Bplus=1,q8.Bplus=1
MIX_C=q1.count.C,q2.daily.C,q3.C,q4.C,q7.C,q8.C
W_C=q1.count.C=4,q2.daily.C=2,q3.C=2,q4.C=1,q7.C=1,q8.C=1
HEAD_C=q1.count.N,q1.count.C,q1.ids.N,q1.ids.C,q2.daily.N,q2.daily.C,q3.N,q3.C,q4.N,q4.C,q7.N,q7.C,q8.N,q8.C
vmix() {   # NAME MODE
    $RV --run=$1 --purpose="refresh under load: 32 clients, weighted bitmap queries (chunk-ordered projection, q7.Bplus), $2; 1 % change batch applied with full validation at 60 s; 600 s measured" --scale="default (tenant 10)" --path="B, B+ + refresh.sh --steps=apply" -- bash -c "python3 bench/driver.py mixed --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 32 --duration 600 --warmup-s 30 --statement-cap 600 --only $MIX_V --weights $W_V --expect $VCHECK --background 'bench/refresh.sh --tenant=10 --fraction=0.01 --spread=random --report=mixed --steps=apply' --background-at 60"
}
bench/limits.sh status --check | tail -1
vmix refresh-under-load-bychunk-t10 fenced
$RV --run=deploy-unfenced-3 --purpose="library redeployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
vmix refresh-under-load-bychunk-unfenced-t10 unfenced
$RV --run=deploy-fenced-3 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes

bench/limits.sh halt
bench/limits.sh start --engine=clickhouse | tail -3
bench/limits.sh status --engine=clickhouse --check | tail -1 || { echo "ClickHouse limits not in place: chain 11 stopped"; echo ALL_DONE; exit 1; }
$RC --run=latency-c1c32-t10 --purpose="ClickHouse latency, six headline queries, N and C, 1 and 32 clients (rerun: the first run stopped at q3.N on a closed keep-alive connection of the driver; fixed)" --scale="tenant 10" --path="N, C" -- bash -c "python3 bench/driver.py run --workload bench/workloads/clickhouse.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only $HEAD_C --expect $VCHECK"
$RC --run=refresh-under-load-t10 --purpose="refresh under load: 32 clients, weighted bitmap queries on snapshot 1 while snapshot 2 (person + daily) is rebuilt at 60 s; 600 s measured (same window as Vertica)" --scale="tenant 10" --path="C + ch.sh build --snapshot=2" -- bash -c "python3 bench/driver.py mixed --workload bench/workloads/clickhouse.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 32 --duration 600 --warmup-s 30 --statement-cap 600 --only $MIX_C --weights $W_C --expect $VCHECK --background 'bench/ch.sh build --tenant=10 --snapshot=2 --only=person,daily' --background-at 60"
bench/ch.sh drop-snapshot --tenant=10 --snapshot=2
bench/limits.sh halt --engine=clickhouse
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1
echo ALL_DONE

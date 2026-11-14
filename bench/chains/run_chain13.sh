#!/usr/bin/env bash
# Chain 13: ClickHouse refresh under load again. In the two earlier runs (chain 8 and chain 11)
# "ch.sh build --snapshot=2" looked for source rows of snapshot 2, found none and rebuilt only the 120
# daily sets (person_sets=0 in its output); those runs are kept and marked. ch.sh now takes
# --source-snapshot and fails on an empty result; here snapshot 2 (547 person sets + 120 daily sets)
# is rebuilt from source snapshot 1 while 32 clients query snapshot 1.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RC="bench/record.sh --area=clickhouse --engine=clickhouse --milestone=M5b"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
MIX_C=q1.count.C,q2.daily.C,q3.C,q4.C,q7.C,q8.C
W_C=q1.count.C=4,q2.daily.C=2,q3.C=2,q4.C=1,q7.C=1,q8.C=1
bench/limits.sh halt
bench/limits.sh start --engine=clickhouse | tail -3
bench/limits.sh status --engine=clickhouse --check | tail -1 || { echo "ClickHouse limits not in place: chain 13 stopped"; bench/limits.sh halt --engine=clickhouse; bench/limits.sh start | tail -2; echo ALL_DONE; exit 1; }
$RC --run=refresh-under-load-full-t10 --purpose="refresh under load: 32 clients, weighted bitmap queries on snapshot 1 while snapshot 2 (547 person sets + 120 daily sets) is rebuilt from source snapshot 1 at 60 s; 600 s measured (rerun: the earlier runs rebuilt only the daily sets)" --scale="tenant 10" --path="C + ch.sh build --snapshot=2 --source-snapshot=1" -- bash -c "python3 bench/driver.py mixed --workload bench/workloads/clickhouse.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 32 --duration 600 --warmup-s 30 --statement-cap 600 --only $MIX_C --weights $W_C --expect $VCHECK --background 'bench/ch.sh build --tenant=10 --snapshot=2 --source-snapshot=1 --only=person,daily' --background-at 60"
bench/ch.sh drop-snapshot --tenant=10 --snapshot=2
bench/limits.sh halt --engine=clickhouse
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1
echo ALL_DONE

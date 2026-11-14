#!/usr/bin/env bash
# Chain 14c: ClickHouse's SQL path for the delivered ID lists, read like everything else in chains
# 14 and 14b (answers kept as raw bytes until the measured block is over), so that the comparison
# chart has all four ID-list bars from the same driver.
set -u
until grep -q ALL_DONE ~/bitmap_record/last_run14b.log; do sleep 30; done
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RC="bench/record.sh --area=clickhouse --engine=clickhouse --milestone=M5c"
REC=~/bitmap_record
VROWS=$(ls -d $REC/vertica/*_ids-rows-fenced-t10 | sort | tail -1)/driver/check.csv
bench/limits.sh halt
bench/limits.sh start --engine=clickhouse | tail -3
if bench/limits.sh status --engine=clickhouse --check | tail -1; then
    $RC --run=ids-rows-sql-raw-t10 --purpose="ClickHouse: ID lists delivered to the client, one row per ID, native SQL; answers kept as raw bytes until the block is over" --scale="tenant 10" --path="N rows" -- bash -c "python3 bench/driver.py run --workload bench/workloads/clickhouse_ids.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only q1.ids.N,q4.N,q8.N --expect $VROWS"
else
    echo "ClickHouse limits not in place: run skipped"
fi
bench/limits.sh halt --engine=clickhouse
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1
echo ALL_DONE

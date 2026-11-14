#!/usr/bin/env bash
# Chain 18b: the native device query at 100 M people read through the socket client. Chain 18 measured
# the bitmap device list at 100 M with the socket client; the native number it is compared with (chain
# 8b) had been read through vsql, which for 197,436 rows is a visible part of 49 ms. Same query, same
# tables, same reader as the bitmap path. 1 client.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5c"
T20CHECK=$(ls -d ~/bitmap_record/vertica/*_latency-bitmap-c1c32-t20b | sort | tail -1)/driver/check.csv
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 18b stopped"; echo ALL_DONE; exit 1; }
$RV --run=native-q4-socket-t20 --purpose="native device query at 100 M people (hand-tuned table), read as raw bytes from the socket like the bitmap list, 1 client" --scale="tenant 20" --path="A" -- bash -c "python3 bench/driver.py run --client socket --workload bench/workloads/vertica.sql --var tenant=20 --out \$BENCH_RUN_DIR/driver --clients 1 --iterations 15 --warmup 1 --statement-cap 300 --only q4.A --expect $T20CHECK"
bench/limits.sh status --check | tail -1
echo ALL_DONE

#!/usr/bin/env bash
# Chain 8b: the rest of chain 8's P5 (100 M people, tenant 20). Chain 8's latency run at 100 M was
# interrupted in its check (kept, invalid): the q7.B text, with a WITH clause read three times, is
# not the form to use at this size. q7.Bj is the same computation with plain subqueries.
# The native Q7 took 2,126 s once in that check; it runs once more here as the oracle of the check
# and is left out of the native latency runs (minutes per execution).
# Appends to last_run8.log, so chain 9 starts after the ALL_DONE at the end.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5b"
HEAD_V=q1.count.Bplus,q1.ids.Bplus,q2.daily.B,q3.Bplus,q4.Bplus,q7.Bj,q8.Bplus
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 8b stopped"; echo ALL_DONE; exit 1; }
$RV --run=latency-bitmap-c1c32-t20b --purpose="latency at 100 M, bitmap paths of the six headline queries (Q7 as q7.Bj: no WITH clause), 1 and 32 clients (fenced); the check runs every native oracle once" --scale="large (tenant 20)" --path="B, B+" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=20 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --only $HEAD_V"
$RV --run=latency-native-c1-t20 --purpose="latency at 100 M, native SQL of the headline queries except Q7 (one execution of 35 min in the checks), 1 client, 3 executions (reduced protocol: native runs take seconds to minutes)" --scale="large (tenant 20)" --path="A" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=20 --out \$BENCH_RUN_DIR/driver --clients 1 --iterations 3 --min-per-client 1 --warmup 0 --only q1.count.A,q1.ids.A,q2.daily.A,q3.A,q4.A,q8.A"
$RV --run=latency-native-c32-t20 --purpose="latency at 100 M, native SQL at 32 clients, one execution each (Q1 count, Q2 daily, Q8)" --scale="large (tenant 20)" --path="A" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=20 --out \$BENCH_RUN_DIR/driver --clients 32 --iterations 32 --min-per-client 1 --warmup 0 --only q1.count.A,q2.daily.A,q8.A"
$RV --run=storage-t20 --purpose="storage with tenant 20 (large) loaded" --scale="tenants 10 + 20" --path="projection_storage" -- bench/storage.sh
echo ALL_DONE

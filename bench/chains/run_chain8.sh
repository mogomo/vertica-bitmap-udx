#!/usr/bin/env bash
# Chain 8 (plan D13): P2 + P4 on ClickHouse and Vertica at 10 M, then P5 (--large, Vertica) overnight.
# One engine at a time; nothing else runs on the workstation meanwhile.
set -u
until grep -q ALL_DONE ~/bitmap_record/last_run7.log; do sleep 30; done
if grep -q 'run_all FAILED' ~/bitmap_record/last_run7.log; then echo "chain 7: run_all failed; chain 8 not started"; echo ALL_DONE; exit 1; fi
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5b"
RC="bench/record.sh --area=clickhouse --engine=clickhouse --milestone=M5b"
REC=~/bitmap_record
last() { ls -d "$REC/$1/"*"_$2"* 2>/dev/null | sort | tail -1; }
HEAD_V=q1.count.Bplus,q1.ids.Bplus,q2.daily.B,q3.Bplus,q4.Bplus,q7.B,q8.Bplus
HEAD_C=q1.count.N,q1.count.C,q1.ids.N,q1.ids.C,q2.daily.N,q2.daily.C,q3.N,q3.C,q4.N,q4.C,q7.N,q7.C,q8.N,q8.C
MIX_C=q1.count.C,q2.daily.C,q3.C,q4.C,q7.C,q8.C
W_C=q1.count.C=4,q2.daily.C=2,q3.C=2,q4.C=1,q7.C=1,q8.C=1
MIX_V=q1.count.Bplus,q2.daily.B,q3.Bplus,q4.Bplus,q7.B,q8.Bplus
W_V=q1.count.Bplus=4,q2.daily.B=2,q3.Bplus=2,q4.Bplus=1,q7.B=1,q8.Bplus=1
sudo mkdir -p /data/xbench && sudo chown "$(id -u):$(id -g)" /data/xbench

# ---- P2: Vertica answers of the headline queries on tenant 10 (reference for --expect) ----------
bench/limits.sh status --check | tail -1
$RV --run=check-headline-t10 --purpose="answers of the six headline queries (native oracles + bitmap paths) on tenant 10 after chain 7; reference for ClickHouse (--expect)" --scale="default (tenant 10)" --path="A, At, B, B+ (check only)" -- bash -c "python3 bench/driver.py check --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --only $HEAD_V"
VCHECK=$(last vertica check-headline-t10)/driver/check.csv
[ -s "$VCHECK" ] || { echo "no Vertica check.csv: chain 8 stopped"; echo ALL_DONE; exit 1; }
$RV --run=export-ch-t10 --purpose="export of tenant 10 (profiles, interests, events, devices) to TSV for ClickHouse" --scale="10 M people, 200 M interests, 100 M events, 2 M devices" --path="bench/ch.sh export" -- bench/ch.sh export --tenant=10 \
    || { echo "export failed: chain 8 stopped"; echo ALL_DONE; exit 1; }

# ---- switch: Vertica down, ClickHouse up with the same limits ----------------------------------
bench/limits.sh halt
bench/limits.sh start --engine=clickhouse | tail -3
bench/limits.sh status --engine=clickhouse --check | tail -1 || { echo "ClickHouse limits not in place: chain 8 stopped"; echo ALL_DONE; exit 1; }
$RC --run=load-t10 --purpose="ClickHouse: schema, load of the exported tenant 10, OPTIMIZE FINAL" --scale="10 M people, 200 M interests, 100 M events, 2 M devices" --path="bench/ch.sh load" -- bench/ch.sh load --tenant=10
$RC --run=build-t10 --purpose="ClickHouse bitmaps (groupBitmap per predicate, per day and channel, per device predicate): build time and storage" --scale="tenant 10" --path="bench/ch.sh build" -- bench/ch.sh build --tenant=10
if $RC --run=check-t10 --purpose="ClickHouse answers (native N and bitmaps C) against Vertica's oracle answers" --scale="tenant 10" --path="N, C (check, --expect Vertica)" -- bash -c "python3 bench/driver.py check --workload bench/workloads/clickhouse.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --expect $VCHECK"; then
    $RC --run=latency-c1c32-t10 --purpose="ClickHouse latency, six headline queries, native N and bitmaps C, 1 and 32 clients (D13 protocol)" --scale="tenant 10" --path="N, C" -- bash -c "python3 bench/driver.py run --workload bench/workloads/clickhouse.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --only $HEAD_C --expect $VCHECK"
    $RC --run=refresh-under-load-t10 --purpose="refresh under load (P4): 32 clients run the bitmap queries on snapshot 1 while snapshot 2 (person + daily sets) is rebuilt from the source at 60 s" --scale="tenant 10" --path="C + ch.sh build --snapshot=2" -- bash -c "python3 bench/driver.py mixed --workload bench/workloads/clickhouse.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 32 --duration 360 --warmup-s 30 --only $MIX_C --weights $W_C --expect $VCHECK --background 'bench/ch.sh build --tenant=10 --snapshot=2 --only=person,daily' --background-at 60"
    bench/ch.sh drop-snapshot --tenant=10 --snapshot=2
else
    echo "ClickHouse answers differ from Vertica: latency runs skipped (see the check run)"
fi
$RC --run=storage-t10 --purpose="ClickHouse storage after the runs" --scale="tenant 10" --path="system.parts" -- bench/ch.sh storage

# ---- switch back: ClickHouse down, Vertica up with its limits ----------------------------------
bench/limits.sh halt --engine=clickhouse
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 8 stopped"; echo ALL_DONE; exit 1; }
$RV --run=refresh-under-load-t10 --purpose="refresh under load (P4): 32 clients run the bitmap queries on snapshot 1 (fenced) while a 1 % change batch is applied with full validation at 60 s (refresh.sh --steps=apply; its cleanup is inside the background window)" --scale="default (tenant 10)" --path="B, B+ + refresh.sh --steps=apply" -- bash -c "python3 bench/driver.py mixed --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 32 --duration 360 --warmup-s 30 --only $MIX_V --weights $W_V --expect $VCHECK --background 'bench/refresh.sh --tenant=10 --fraction=0.01 --spread=random --report=mixed --steps=apply' --background-at 60"

# ---- P5: --large (tenant 20), Vertica only ------------------------------------------------------
W="2026-11-01 00:00:00"
$RV --run=generate-large-t20 --purpose="generator --large: 100 M people, 2 B interests (20 each, skew 1.5), 1 B events, 20 M devices, 50 M assets" --scale="large" --path="scripts/generate.sh --large" -- scripts/generate.sh --tenant=20 --snapshot=1 --large --topic-skew=1.5 --id-order=signup --id-space=dense \
    || { echo "large generation failed: chain stopped"; echo ALL_DONE; exit 1; }
$RV --run=build-person-t20 --purpose="lifecycle build at 100 M: person index + daily sets, with validation" --scale="large (tenant 20)" --path="snapshot.sh build --daily --publish" -- scripts/snapshot.sh build --tenant=20 --domain=person --snapshot=1 --source-snapshot=1 --watermark="$W" --daily --publish \
    || { echo "large build failed: chain stopped"; echo ALL_DONE; exit 1; }
$RV --run=build-device-t20 --purpose="lifecycle build at 20 M devices" --scale="large (tenant 20)" --path="snapshot.sh build --publish" -- scripts/snapshot.sh build --tenant=20 --domain=device --snapshot=1 --source-snapshot=1 --watermark="2026-11-01 12:00:00" --publish
$RV --run=latency-bitmap-c1c32-t20 --purpose="latency at 100 M, bitmap paths of the six headline queries, 1 and 32 clients (fenced); the check runs every native oracle once" --scale="large (tenant 20)" --path="B, B+" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=20 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --only $HEAD_V"
$RV --run=latency-native-c1-t20 --purpose="latency at 100 M, native SQL of the six headline queries, 1 client, 3 executions (reduced protocol: native runs take minutes)" --scale="large (tenant 20)" --path="A, At" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=20 --out \$BENCH_RUN_DIR/driver --clients 1 --iterations 3 --min-per-client 1 --warmup 0 --only q1.count.A,q1.ids.A,q2.daily.A,q3.A,q4.A,q7.At,q8.A"
$RV --run=latency-native-c32-t20 --purpose="latency at 100 M, native SQL at 32 clients, one execution each (Q1 count, Q2 daily, Q8)" --scale="large (tenant 20)" --path="A" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=20 --out \$BENCH_RUN_DIR/driver --clients 32 --iterations 32 --min-per-client 1 --warmup 0 --only q1.count.A,q2.daily.A,q8.A"
$RV --run=storage-t20 --purpose="storage with tenant 20 (large) loaded" --scale="tenants 10 + 20" --path="projection_storage" -- bench/storage.sh
echo ALL_DONE

#!/usr/bin/env bash
# Chain 18: three completions of the record, with the final library and the socket client.
#  1. Native ID lists read the same way as the bitmap lists. The native numbers of the article are the
#     faster of hand-tuned and Database Designer projections; the long native ID lists had been read
#     through vsql. The Designer copy of tenant 10 is made again exactly as in run_dbd_t10.sh and the
#     native ID-list queries are measured on it (and Q4 on the hand-tuned table too) with
#     --client socket, 1 and 32 clients.
#  2. The 100 M tenant (tenant 20) again, fenced and unfenced: the six questions, the every-thread
#     forms and the ID lists as text blocks at 1 client; the audience count and the daily distinct
#     users at 32 clients (32 simultaneous facet breakdowns over 100 M people are a stress test,
#     measured once in chain 8b). Answers are checked against chain 8b's native oracle answers.
#  3. Totals of an attribute over an audience without a join: the age as bit-sliced sets
#     (sql/families_bitsliced.sql, bench/bitsliced.sh), q8.agg.Bplus next to the join form q8.join.Bplus
#     in the same run; unfenced and fenced, 10 M (1 / 32 clients) and 100 M (1 client; the two answer
#     groups that had no 100 M oracle, q8.sum and q8.join, get one native execution first). ClickHouse
#     gets the same sets (bench/ch.sh build-bits) and the same question (q8.agg.C next to q8.join.C).
# Every statement is capped.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5c"
RC="bench/record.sh --area=clickhouse --engine=clickhouse --milestone=M5c"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
XUSE=$REC/vertica/2026-11-13_ids-use-fenced-t10/driver/check.csv
T20CHECK=$(ls -d $REC/vertica/*_latency-bitmap-c1c32-t20b | sort | tail -1)/driver/check.csv
D="python3 bench/driver.py"
MK="python3 bench/make_dbd_workload.py --workload bench/workloads/vertica.sql --var tenant=10 --out-workload \$BENCH_RUN_DIR/dbd_workload.sql --out-queries \$BENCH_RUN_DIR/dbd_queries.sql"
AGG=q8.agg.Bplus,q8.join.Bplus,q8.sum.Bplus
HEAD20=q1.count.Bplus,q1.ids.Bplus,q2.daily.B,q3.Bplus,q4.Bplus,q7.Bj,q7.Bplus,q8.Bplus
vrun() {   # NAME PURPOSE PATH WORKLOAD TENANT CLIENTS ONLY [driver options]
    local name=$1 purpose=$2 path=$3 wl=$4 tenant=$5 clients=$6 only=$7; shift 7
    $RV --run="$name" --purpose="$purpose" --scale="tenant $tenant" --path="$path" -- bash -c "$D run --client socket --workload bench/workloads/$wl --var tenant=$tenant --out \$BENCH_RUN_DIR/driver --clients $clients --iterations 15 --warmup 1 --statement-cap 300 --only $only $*"
}
vmode() {   # fenced|unfenced: the 100 M tenant
    local m=$1
    vrun final-headline-$m-t20 "the six questions at 100 M people with the final library, socket client, 1 client, $m" "B, B+" vertica.sql 20 1 $HEAD20 --expect $T20CHECK --skip-oracles
    vrun final-headline-c32-$m-t20 "audience count and daily distinct users at 100 M people, 32 clients, $m" "B, B+" vertica.sql 20 32 q1.count.Bplus,q2.daily.B --expect $T20CHECK --skip-oracles
    vrun final-par-$m-t20 "facets and overlap at 100 M people on every thread of the query (bm_pair_count OVER (PARTITION BEST)), 1 client, $m" "Bpar" vertica.sql 20 1 q3.Bpar,q7.Bpar --expect $T20CHECK --skip-oracles
    vrun final-ids-text-$m-t20 "ID lists at 100 M people as text blocks (bm_ids_text): 2.5 M and 5.3 M IDs, 1 client, $m" "B+ text" vertica_ids.sql 20 1 q1.ids.text.Bplus,q8.text.Bplus --expect $T20CHECK --skip-oracles
}
amode() {   # fenced|unfenced: attribute totals over an audience, with and without a join
    local m=$1
    vrun final-agg-$m-t10 "people, known ages and sum of ages of the Q8 audience: from bit-sliced sets alone (q8.agg) and by joining the ID list to the profile table (q8.join); count and sum of the IDs again in the same run; $m" "B+ agg, B+ join, B+ sum" vertica_ids.sql 10 1,32 $AGG --expect $XUSE --skip-oracles
    vrun final-agg-$m-t20 "people, known ages and sum of ages of the Q8 audience at 100 M people: bit-sliced sets, join to the profile table, count and sum of the IDs; 1 client, $m" "B+ agg, B+ join, B+ sum" vertica_ids.sql 20 1 $AGG --expect $T20AGG --skip-oracles
}
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 18 stopped"; echo ALL_DONE; exit 1; }
cp bench/chains/status.sh $REC/status.sh
$RV --run=deploy-fenced-12 --purpose="final library deployed fenced" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes

# ---- 1. native ID lists on the Database Designer copy, socket client ----------------------------
bench/dbd.sh drop
$RV --run=dbd2-copy-t10 --purpose="copy of the native source tables of tenant 10 into schema bitmap_dbd (no projections), as run 38" --scale="tenant 10" --path="bench/dbd.sh copy" -- bench/dbd.sh copy --tenant=10 \
 && $RV --run=dbd2-design-t10 --purpose="Database Designer: comprehensive design, objective QUERY, K-safety 0, the 15 native workload queries, populated and deployed on bitmap_dbd, as run 39" --scale="tenant 10" --path="DESIGNER_* (bench/dbd.sh design)" -- bash -c "$MK && bench/dbd.sh design --queries=\$BENCH_RUN_DIR/dbd_queries.sql --out=\$BENCH_RUN_DIR/dbd" \
 && $RV --run=native-ids-socket-t10 --purpose="native ID lists read as raw bytes from the socket, like the bitmap lists: Q1 IDs, Q4 and Q8 on the Database Designer projections (D) and Q4 on the hand-tuned table (A), 1 and 32 clients" --scale="tenant 10 / copy" --path="A, D" -- bash -c "$MK && $D run --client socket --workload \$BENCH_RUN_DIR/dbd_workload.sql --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only q1.ids.D,q4.A,q4.D,q8.D --expect $VCHECK --skip-oracles"

# ---- 2. the 100 M tenant, fenced, then unfenced (before any set is added to the index) ----------
vmode fenced
$RV --run=deploy-unfenced-12 --purpose="final library deployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
vmode unfenced

# ---- 3. bit-sliced sets added to the published snapshots; totals with and without a join -------
$RV --run=bitsliced-add-t10 --purpose="age as bit-sliced sets (family age_bits) added to person snapshot 1 of tenant 10, unfenced" --scale="tenant 10" --path="bench/bitsliced.sh add" -- bench/bitsliced.sh add --tenant=10
$RV --run=bitsliced-add-t20 --purpose="age as bit-sliced sets (family age_bits) added to person snapshot 1 of tenant 20, unfenced" --scale="tenant 20" --path="bench/bitsliced.sh add" -- bench/bitsliced.sh add --tenant=20
$RV --run=check-agg-t20 --purpose="reference answers at 100 M people for the ID-list uses that had none: count and sum of the Q8 IDs, the Q8 audience joined to the profile table (native oracles, one execution each) and the three bitmap forms, unfenced" --scale="tenant 20" --path="A, B+" -- bash -c "$D check --client socket --workload bench/workloads/vertica_ids.sql --var tenant=20 --out \$BENCH_RUN_DIR/driver --statement-cap 1800 --only $AGG"
T20AGG=$(ls -d $REC/vertica/*_check-agg-t20 | sort | tail -1)/driver/check.csv
amode unfenced
$RV --run=deploy-fenced-13 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
amode fenced

# ---- ClickHouse: the same sets, the same question -----------------------------------------------
bench/limits.sh halt
bench/limits.sh start --engine=clickhouse | tail -3
if bench/limits.sh status --engine=clickhouse --check | tail -1; then
    $RC --run=build-bits-t10 --purpose="ClickHouse: age as bit-sliced sets (age_bit_0 ... age_bit_7) added to the person sets of tenant 10" --scale="tenant 10" --path="bench/ch.sh build-bits" -- bench/ch.sh build-bits --tenant=10
    $RC --run=ids-agg-t10 --purpose="ClickHouse: people, known ages and sum of ages of the Q8 audience: from bit-sliced sets alone (q8.agg.C) and by testing every profile row against the bitmap (q8.join.C), same run" --scale="tenant 10" --path="C agg, C join" -- bash -c "$D run --workload bench/workloads/clickhouse_ids.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only q8.agg.C,q8.join.C --expect $XUSE"
else
    echo "ClickHouse limits not in place: ClickHouse part of chain 18 skipped"
fi
bench/limits.sh halt --engine=clickhouse
bench/limits.sh start | tail -2
bench/limits.sh status --check | tail -1
echo ALL_DONE

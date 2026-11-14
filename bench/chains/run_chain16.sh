#!/usr/bin/env bash
# Chain 16: facets and overlap on every thread of the query. bm_facets and the other expression
# functions work through the chunks of a query in order, one pass, one thread; the new
# bm_pair_count takes independent rows (the audience of the chunk joined to each facet set) and is
# called OVER (PARTITION BEST), so that Vertica spreads the rows over the query's threads. Measured at 1 and 32
# clients, fenced and unfenced, with the same driver and library as chain 15 (q3.Bplus and
# q7.Bplus are measured again next to them, so that both forms come from the same run).
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5c"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
SET=q3.Bplus,q3.Bpar,q7.Bplus,q7.Bpar
vrun() {   # NAME MODE
    $RV --run="$1" --purpose="facets and overlap: one pass per chunk on one thread (Bplus) and independent rows on every thread of the query (Bpar: bm_eval joined to the sets, bm_pair_count OVER (PARTITION BEST)), $2" --scale="tenant 10" --path="B+, Bpar" -- bash -c "python3 bench/driver.py run --client socket --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only $SET --expect $VCHECK --skip-oracles"
}
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 16 stopped"; echo ALL_DONE; exit 1; }
$RV --run=deploy-fenced-9 --purpose="library with bm_pair_count deployed fenced" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
vrun final-par-fenced-t10 fenced
$RV --run=deploy-unfenced-9 --purpose="library with bm_pair_count deployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
vrun final-par-unfenced-t10 unfenced
$RV --run=deploy-fenced-10 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
bench/limits.sh status --check | tail -1
echo ALL_DONE

#!/usr/bin/env bash
# Chain 17: a tuning experiment. The person index of tenant 10 is copied into a table stored in 16
# containers (partitions of 10 chunks, bench/vertica_index_partitioned.sql) and the audience count
# and the two facet forms are measured on it, unfenced, next to the same queries on the index table
# in the same run.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5c"
REC=~/bitmap_record
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
SET=q1.count.Bplus,q3.Bplus,q3.Bpar
vrun() {   # NAME PURPOSE INDEX
    $RV --run="$1" --purpose="$2" --scale="tenant 10" --path="B+, Bpar" -- bash -c "python3 bench/driver.py run --client socket --workload bench/workloads/vertica.sql --var tenant=10 --var index=$3 --out \$BENCH_RUN_DIR/driver --clients 1,32 --iterations 15 --warmup 1 --statement-cap 300 --only $SET --expect $VCHECK --skip-oracles"
}
bench/limits.sh status --check | tail -1 || { echo "Vertica limits not in place: chain 17 stopped"; echo ALL_DONE; exit 1; }
vsql -X -q -c "DROP TABLE IF EXISTS bitmap_bench.ix_part16 CASCADE; DROP TABLE IF EXISTS bitmap_bench.ix_part64 CASCADE; DROP TABLE IF EXISTS bitmap_bench.one_audience CASCADE;"
$RV --run=deploy-unfenced-10 --purpose="library deployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
$RV --run=index-parts-t10 --purpose="copy of the person index stored in 16 containers (partitions of 10 chunks)" --scale="tenant 10" --path="bench/vertica_index_partitioned.sql" -- vsql -X -q -A -t -v ON_ERROR_STOP=1 -v tenant=10 -v snapshot=1 -v per_partition=10 -f bench/vertica_index_partitioned.sql
vrun tuning-parts16-unfenced-t10 "audience count and facets (one pass; every thread) on the index stored in 16 containers, unfenced" bitmap_bench.bitmap_index_parts
vrun tuning-parts1-unfenced-t10 "the same three queries on the index table (chunk-ordered projection, one container), unfenced, same session of measurements" bitmap_demo.bitmap_index
$RV --run=deploy-fenced-11 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
bench/limits.sh status --check | tail -1
echo ALL_DONE

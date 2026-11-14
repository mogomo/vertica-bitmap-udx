set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
R="bench/record.sh --area=vertica"
MK="python3 bench/make_dbd_workload.py --workload bench/workloads/vertica.sql --var tenant=10 --out-workload \$BENCH_RUN_DIR/dbd_workload.sql --out-queries \$BENCH_RUN_DIR/dbd_queries.sql"
$R --run=dbd-copy-t10 --purpose="copy of the native source tables of tenant 10 into schema bitmap_dbd (no projections) for the Database Designer comparison" --scale="default (tenant 10)" --path="bench/dbd.sh copy" -- bench/dbd.sh copy --tenant=10 || { echo ALL_DONE; exit 1; }
$R --run=dbd-design-t10 --purpose="Database Designer: comprehensive design, objective QUERY, K-safety 0, the 15 native workload queries, populated and deployed on bitmap_dbd" --scale="default (tenant 10)" --path="DESIGNER_* (bench/dbd.sh design)" -- bash -c "$MK && bench/dbd.sh design --queries=\$BENCH_RUN_DIR/dbd_queries.sql --out=\$BENCH_RUN_DIR/dbd" || { echo ALL_DONE; exit 1; }
$R --run=dbd-latency-c1-t10 --purpose="latency, 1 client: native queries on hand-tuned projections (A, At) against the Database Designer design (D, Dt)" --scale="default (tenant 10)" --path="A, At, D, Dt" -- bash -c "$MK && python3 bench/driver.py run --workload \$BENCH_RUN_DIR/dbd_workload.sql --out \$BENCH_RUN_DIR/driver --clients 1 --iterations 30 --warmup 1"
$R --run=dbd-latency-c8c32-t10 --purpose="latency, 8 and 32 clients: A, At against D, Dt (all but q7.A and q7.D)" --scale="default (tenant 10)" --path="A, At, D, Dt" -- bash -c "$MK && python3 bench/driver.py run --workload \$BENCH_RUN_DIR/dbd_workload.sql --out \$BENCH_RUN_DIR/driver --clients 8,32 --iterations 30 --min-per-client 1 --warmup 1 --only \$(grep -oE '^-- @query [^ ]+' \$BENCH_RUN_DIR/dbd_workload.sql | cut -d' ' -f3 | grep -vxE 'q7\.(A|D)' | paste -sd,)"
echo ALL_DONE

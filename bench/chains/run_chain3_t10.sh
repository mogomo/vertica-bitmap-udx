set -u
until grep -q ALL_DONE ~/bitmap_record/last_run2.log; do sleep 20; done
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
R="bench/record.sh --area=vertica"
$R --run=purge-index-t10 --purpose="purge deleted scratch rows of run 25 from the index tables" --scale="index tables" --path="PURGE_TABLE" -- bash -c "vsql -X -A -t -v ON_ERROR_STOP=1 -c \"SELECT PURGE_TABLE('bitmap_demo.bitmap_index'); SELECT PURGE_TABLE('bitmap_demo.daily_bitmap'); SELECT PURGE_TABLE('bitmap_demo.bitmap_predicate');\" && bench/storage.sh"
$R --run=sweep-t10 --purpose="sweeps: 2 / 8 / 32 predicates and selectivity 0.01 / 1 / 10 / 50 %, native A against B+" --scale="default (tenant 10)" --path="A (written from the expression), B+ (bmq SQL)" -- bash -c "python3 bench/make_sweep.py --tenant=10 --out \$BENCH_RUN_DIR/sweep.sql && python3 bench/driver.py run --workload \$BENCH_RUN_DIR/sweep.sql --out \$BENCH_RUN_DIR/driver --clients 1,8,32 --iterations 30 --min-per-client 1 --warmup 1"
$R --run=deploy-unfenced --purpose="redeploy the library unfenced for the fenced/unfenced comparison" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
$R --run=latency-unfenced-t10 --purpose="latency, 1 / 8 / 32 clients, paths B and B+ with the library unfenced" --scale="default (tenant 10)" --path="B, B+ unfenced" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1,8,32 --iterations 30 --min-per-client 1 --warmup 1 --only q1.count.B,q1.count.Bplus,q1.ids.B,q1.ids.Bplus,q2.B,q2.daily.B,q2b.B,q3.B,q3.Bplus,q3d.Bplus,q4.B,q4.Bplus,q5.B,q5.Bplus,q6.B,q7.B,q8.B,q8.Bplus,q8trap.Bplus"
$R --run=deploy-fenced --purpose="redeploy the library fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
echo ALL_DONE

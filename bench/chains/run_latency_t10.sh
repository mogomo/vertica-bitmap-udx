set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
R="bench/record.sh --area=vertica"
$R --run=floor --purpose="latency floor and client headroom (V17): SELECT 1" --scale="none" --path="vsql session per client" -- bash -c "python3 bench/driver.py run --workload bench/workloads/floor.sql --out \$BENCH_RUN_DIR/driver --clients 1,8,32 --iterations 300 --warmup 5"
$R --run=latency-c1-t10 --purpose="latency, 1 client, every path, default projections, fenced" --scale="default (tenant 10)" --path="A, B, B+, approx" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 1 --iterations 30 --warmup 1"
$R --run=latency-c8c32-t10 --purpose="latency, 8 and 32 clients, every path except q7.A, default projections, fenced" --scale="default (tenant 10)" --path="A, B, B+, approx" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=10 --out \$BENCH_RUN_DIR/driver --clients 8,32 --iterations 30 --min-per-client 1 --warmup 1 --only q1.count.A,q1.count.B,q1.count.Bplus,q1.ids.A,q1.ids.B,q1.ids.Bplus,q2.A,q2.B,q2.approx,q2.daily.A,q2.daily.B,q2b.A,q2b.B,q3.A,q3.B,q3.Bplus,q3d.A,q3d.Bplus,q4.A,q4.B,q4.Bplus,q5.A,q5.B,q5.Bplus,q6.A,q6.B,q7.B,q8.A,q8.B,q8.Bplus,q8trap.A,q8trap.Bplus"
echo ALL_DONE

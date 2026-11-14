set -u
until grep -q ALL_DONE ~/bitmap_record/last_run6.log; do sleep 30; done
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
R="bench/record.sh --area=vertica"
W="2026-11-01 00:00:00"
BITMAP=q1.count.B,q1.count.Bplus,q1.ids.B,q1.ids.Bplus,q2.B,q2.daily.B,q2b.B,q3.B,q3.Bplus,q3d.Bplus,q6.B,q7.B,q8.B,q8.Bplus,q8trap.Bplus
PERSON=q1.count.A,q1.count.Bplus,q1.ids.A,q1.ids.Bplus,q2.A,q2.B,q2.daily.A,q2.daily.B,q2b.A,q2b.B,q3.A,q3.B,q3.Bplus,q3d.A,q3d.Bplus,q6.A,q6.B,q7.At,q7.B,q8.A,q8.B,q8.Bplus,q8trap.A,q8trap.Bplus
bench/dbd.sh drop
bench/limits.sh status --check | tail -1
# --- 18 chunk bits on tenant 10 (person snapshot 2, not published)
$R --run=build-person-cb18-t10 --purpose="person index + daily sets with 18 chunk bits (snapshot 2, not published), with validation" --scale="default (tenant 10)" --path="snapshot.sh build --chunk-bits=18" -- scripts/snapshot.sh build --tenant=10 --domain=person --snapshot=2 --source-snapshot=1 --watermark="$W" --chunk-bits=18 --daily
$R --run=latency-cb18-t10 --purpose="latency, 1 client, bitmap paths on the 18-chunk-bit person index (compare runs 22, 33: 16 bits)" --scale="default (tenant 10)" --path="B, B+ (chunk bits 18)" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=10 --var psnap=2 --out \$BENCH_RUN_DIR/driver --clients 1 --iterations 30 --warmup 1 --only $BITMAP"
scripts/snapshot.sh discard --tenant=10 --domain=person --snapshot=2
# --- variant tenants: people, interests, events only
variant() {   # TENANT NAME GENERATOR-OPTIONS...
    local t=$1 name=$2; shift 2
    $R --run=generate-$name-t$t --purpose="generator, 10 M people, 100 M events, $name ($*)" --scale="10 M people, 200 M interests, 100 M events" --path="scripts/generate.sh" -- scripts/generate.sh --tenant=$t --snapshot=1 --users=10000000 --events=100000000 "$@" || return 1
    $R --run=build-person-t$t --purpose="lifecycle build, person index + daily sets, $name" --scale="tenant $t" --path="snapshot.sh build --daily --publish" -- scripts/snapshot.sh build --tenant=$t --domain=person --snapshot=1 --source-snapshot=1 --watermark="$W" --daily --publish || return 1
    $R --run=latency-$name-t$t --purpose="latency, 1 client, person queries, $name (compare run 22, tenant 10)" --scale="tenant $t ($name)" --path="A, At, B, B+" -- bash -c "python3 bench/driver.py run --workload bench/workloads/vertica.sql --var tenant=$t --out \$BENCH_RUN_DIR/driver --clients 1 --iterations 30 --warmup 1 --only $PERSON"
}
variant 11 uniform-topics --topic-skew=0 --id-order=signup --id-space=dense
variant 12 random-ids --topic-skew=1.5 --id-order=random --id-space=dense
variant 13 clustered-ids --topic-skew=1.5 --id-order=clustered --id-space=dense
variant 14 wide-ids --topic-skew=1.5 --id-order=signup --id-space=wide
$R --run=storage-variants --purpose="storage with tenants 10 to 14 (per table; rows per tenant in the tenants lines)" --scale="tenants 10 to 14" --path="projection_storage" -- bench/storage.sh
# --- regression tests of the new code (drops schema bitmap_demo: every tenant), then tenant 10 again
tests/sql/run_all.sh > ~/bitmap_record/run_all_chain7.log 2>&1 || { tail -30 ~/bitmap_record/run_all_chain7.log; echo "run_all FAILED: chain stopped"; echo ALL_DONE; exit 1; }
tail -1 ~/bitmap_record/run_all_chain7.log
$R --run=generate-default-t10 --purpose="generator, --default, skewed topics 1.5, signup IDs, dense (tenant 10 again after run_all dropped the schema; same command as run 15)" --scale="10 M people, 200 M interests, 100 M events, 2 M devices, 5 M assets" --path="scripts/generate.sh" -- scripts/generate.sh --tenant=10 --snapshot=1 --default --topic-skew=1.5 --id-order=signup --id-space=dense || { echo ALL_DONE; exit 1; }
$R --run=build-person-t10 --purpose="lifecycle build, person index + daily sets, with validation (again, as run 16)" --scale="10 M people, 200 M interests, 100 M events" --path="snapshot.sh build --daily --publish" -- scripts/snapshot.sh build --tenant=10 --domain=person --snapshot=1 --source-snapshot=1 --watermark="$W" --daily --publish || { echo ALL_DONE; exit 1; }
$R --run=build-device-t10 --purpose="lifecycle build, device index (again, as run 17)" --scale="2 M devices" --path="snapshot.sh build --publish" -- scripts/snapshot.sh build --tenant=10 --domain=device --snapshot=1 --source-snapshot=1 --watermark="2026-11-01 12:00:00" --publish
$R --run=build-asset-t10 --purpose="lifecycle build, asset index (again, as run 18)" --scale="5 M assets, 10 M sources" --path="snapshot.sh build --publish" -- scripts/snapshot.sh build --tenant=10 --domain=asset --snapshot=1 --source-snapshot=1 --watermark="$W" --publish
$R --run=projections-tuned-t10 --purpose="tuned native projection again (as run 26)" --scale="10 M profiles" --path="bench/vertica_projections.sql" -- bash -c "vsql -X -v ON_ERROR_STOP=1 -e -f bench/vertica_projections.sql && echo summary: projection=user_profile_by_filter created=yes"
# --- refresh (plan: 0.1 / 1 / 10 %), incremental vs full, touched-only vs full validation
refresh() {   # NAME OPTIONS...
    local name=$1; shift
    $R --run=refresh-$name-t10 --purpose="refresh of the person index: $* (full build, apply with touched-only validation, apply with full validation; byte-for-byte comparison)" --scale="default (tenant 10)" --path="bench/refresh.sh" -- bench/refresh.sh --tenant=10 "$@"
}
refresh 0.1pct-random-mixed --fraction=0.001 --spread=random --report=mixed
refresh 1pct-random-mixed --fraction=0.01 --spread=random --report=mixed
refresh 10pct-random-mixed --fraction=0.1 --spread=random --report=mixed
refresh 1pct-recent-mixed --fraction=0.01 --spread=recent --report=mixed
refresh 1pct-random-delta --fraction=0.01 --spread=random --report=delta
$R --run=storage-t10-after-refresh --purpose="storage after the refresh runs (all scratch rows deleted and purged)" --scale="tenant 10 + fixture tenants" --path="projection_storage" -- bench/storage.sh
echo ALL_DONE

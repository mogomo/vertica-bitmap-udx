#!/usr/bin/env bash
# Measures the bitmap benchmark of the article (blog/BLOG.md) again, on your own machine, from an
# empty tenant to a report. One script, the steps in the order of the article; every measurement
# is a recorded run (bench/record.sh) with raw timings, answers, plans and settings.
#
#   bench/reproduce.sh [options] [STEP ...]          no STEP: every step of "all" in order
#
# Steps
#   setup       build the library and the expression tool, deploy the functions fenced, create
#               schema bitmap_demo if it is missing
#   data        generate the tenant's data (scripts/generate.sh; --size)
#   index       build, validate and publish the person index with its daily sets and the device
#               index (transform builder: the build times of the article); the bit-sliced age
#               sets; the second index projection sorted by chunk; the hand-tuned native projection
#   native      the native SQL baseline: a copy of the source tables designed by Vertica's Database
#               Designer, then the native queries on the hand-tuned projections (A, At) and on the
#               Designer's (D, Dt) at 1 and 32 clients. The article reports the faster of the two.
#   bitmap      reference answers, then with the functions fenced and again unfenced: the six
#               questions at 1 and 32 clients, facets and overlap on every thread, ID lists
#               (rows, text rows, text blocks; used inside the engine; row filter; bit-sliced
#               totals; saved), and unfenced the aggregate builder
#   refresh     the three incremental refresh tests after 1 % of the people changed
#   live        the live index (a live aggregate projection): maintained load, queries, and an
#               append of 1 % more tag rows while 32 clients query. Uses schema bitmap_live:
#               the step refuses to run if that schema exists, unless --replace-live is given
#   clickhouse  export the tenant, stop Vertica, start ClickHouse with the same limits, load,
#               build its bitmaps, check every answer against Vertica's, measure the six
#               questions (SQL and bitmaps) and the ID lists; then stop it and start Vertica again
#   report      REPORT.md in the record folder: latency tables of every run (bench/report.py) and
#               the summary lines of the builds, the refresh tests and the live append
#   finish      functions deployed fenced again; with limits: Vertica restarted without them
#   all         setup data index native bitmap refresh clickhouse report finish
#               (live is left out of "all" because it owns schema bitmap_live; name it to run it)
#   cleanup     remove the tenant's rows, the Designer copy, the scratch schema of the save tests
#               and the exported files (never part of "all")
#
# Options
#   --tenant=N            tenant number that holds the data (default 30; must be unused for "data")
#   --size=small|default|large   1 M, 10 M (the article's main scale) or 100 M people (default: default)
#   --clients=1,32        client counts of the latency runs
#   --iterations=15       measured executions per query and client count (at least two per client)
#   --record-dir=DIR      where the run folders go (default ~/bitmap_reproduce)
#   --no-limits           do not put the engine into a cgroup (a first try on a small machine;
#                         the runs are then marked "engine not inside its limits")
#   --cpus=0-19 --memory=56G --pool-memory=50G --planned-concurrency=20
#                         the engine's limits (bench/limits.sh); the defaults are the article's
#   --client-cpus=20,21   CPUs of the benchmark client, outside --cpus
#   --dbd-schema=bitmap_dbd      schema of the Database Designer copy (dropped and created); its
#                         design is named <schema>_design and is dropped once it is deployed
#   --export-dir=/data/xbench/export   where the rows for ClickHouse are written (about 12 GB at
#                         the default size)
#   --build-memory=40G    MAXMEMORYSIZE of the resource pool of the aggregate builder (pool
#                         bitmap_build, created if it is missing); on a smaller machine give a
#                         smaller size or a share of the memory, such as 60%
#   --replace-live        let the step "live" drop and re-create schema bitmap_live
#
# Needs: a Vertica 26.3 node with the C++ SDK, run as the database administrator; the VSQL_*
# connection variables, VSQL_DATABASE in any case (VSQL_PASSWORD if the database has one);
# python3 (3.6 or later), bc. With limits (the default):
# passwordless sudo for systemd-run. For the step "clickhouse": the ClickHouse packages
# (bench/engines/clickhouse/VERSION), started by this script as its own instance; CH_HOME names its
# folder (default /data/xbench/clickhouse).
# One engine runs at a time and nothing else should run on the machine during a measured step.
# A database with several nodes works too (use --no-limits there: the limits are made for one
# node): one test, the row filter on a pinned set, is then left out.
# The source tables are shared by all tenants of schema bitmap_demo. For native numbers like the
# article's, the tenant should be the only large one in them: native SQL on a small tenant pays
# for the rows of a large one next to it, the bitmap paths do not.
#
# Time at the default size on the article's machine: data 3 min, index 6 min, native 40 min,
# bitmap 60 min, refresh 15 min, live 15 min, clickhouse 45 min. Try "--size=small" first: every
# step then takes a few minutes. A step can be repeated; a later run of the same name gets a
# folder with a suffix, and the report uses the newest.
#
# The measurements beyond these (sweeps, 64-bit IDs, the 16-container layout, refresh under load,
# payload encodings) are in bench/chains/, as the command sequences that produced them.
set -euo pipefail

cd "$(dirname "$0")/.."

# ---- options ---------------------------------------------------------------------------------
TENANT=30; SIZE=default; CLIENTS=1,32; ITER=15
REC="${BITMAP_RECORD_DIR:-$HOME/bitmap_reproduce}"
LIMITS=yes; CPUS=0-19; MEM=56G; POOL_MEM=50G; PLANNED=20; CLIENT_CPUS=20,21
DBD_SCHEMA=bitmap_dbd; EXPORT_DIR=/data/xbench/export; BUILD_MEM=40G; REPLACE_LIVE=no
STEPS=()
for arg in "$@"; do
    case "$arg" in
        --tenant=*)              TENANT="${arg#*=}" ;;
        --size=*)                SIZE="${arg#*=}" ;;
        --clients=*)             CLIENTS="${arg#*=}" ;;
        --iterations=*)          ITER="${arg#*=}" ;;
        --record-dir=*)          REC="${arg#*=}" ;;
        --no-limits)             LIMITS=no ;;
        --cpus=*)                CPUS="${arg#*=}" ;;
        --memory=*)              MEM="${arg#*=}" ;;
        --pool-memory=*)         POOL_MEM="${arg#*=}" ;;
        --planned-concurrency=*) PLANNED="${arg#*=}" ;;
        --client-cpus=*)         CLIENT_CPUS="${arg#*=}" ;;
        --dbd-schema=*)          DBD_SCHEMA="${arg#*=}" ;;
        --export-dir=*)          EXPORT_DIR="${arg#*=}" ;;
        --build-memory=*)        BUILD_MEM="${arg#*=}" ;;
        --replace-live)          REPLACE_LIVE=yes ;;
        -h|--help)               sed -n '2,77p' "$0"; exit 0 ;;
        --*)                     echo "reproduce.sh: unknown option: $arg (see --help)" >&2; exit 2 ;;
        *)                       STEPS+=("$arg") ;;
    esac
done
[ ${#STEPS[@]} -gt 0 ] || STEPS=(all)
die() { echo "reproduce.sh: $*" >&2; exit 1; }
[[ "$TENANT" =~ ^[0-9]+$ ]] || die "--tenant must be a number"
case "$SIZE" in small|default|large) ;; *) die "--size is small, default or large" ;; esac
[[ "$CLIENTS" =~ ^[0-9]+(,[0-9]+)*$ && "$ITER" =~ ^[0-9]+$ ]] || die "bad --clients or --iterations"
[[ "$DBD_SCHEMA" =~ ^[A-Za-z0-9_]+$ ]] || die "bad --dbd-schema"
[ -n "${VSQL_DATABASE:-}" ] || die "set VSQL_DATABASE (the name of the database)"
export PATH="/opt/vertica/bin:$PATH"
command -v vsql > /dev/null || die "vsql not found"

# The benchmark client is pinned to its own CPUs (bench/record.sh). They must exist, and with
# limits they must lie outside the engine's CPUs: the article's machine has 22, the engine gets
# 0-19 and the client 20 and 21.
NCPU=$(nproc --all)
for c in ${CLIENT_CPUS//,/ }; do
    [ "$c" -lt "$NCPU" ] || die "client CPU $c does not exist on this machine ($NCPU CPUs): give --client-cpus (and --cpus, --memory, --pool-memory, --planned-concurrency), or try --no-limits --client-cpus=$((NCPU - 2)),$((NCPU - 1))"
done

mkdir -p "$REC"
export BITMAP_RECORD_DIR="$REC"       # read by bench/record.sh
RUNS="$REC/runs.tsv"                   # name <tab> folder of every run this script recorded
touch "$RUNS"
W="2026-11-01 00:00:00"                # watermark of the person index (the generator's last day)
DW="2026-11-01 12:00:00"               # watermark of the device index
SCALE_TEXT="tenant $TENANT, --$SIZE"
CAP=300                                # seconds a single statement may take in a latency run
LIMIT_OPTS=(--cpus="$CPUS" --memory="$MEM" --pool-memory="$POOL_MEM" --planned-concurrency="$PLANNED")
VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { printf '%s\n' "$1" | "${VSQL[@]}"; }
say() { echo; echo "==== $* ($(date +%T))"; }

# ---- recording -------------------------------------------------------------------------------
# rec ENGINE NAME PURPOSE COMMAND...   runs COMMAND as a recorded run and notes its folder.
# A command that fails (a statement in error, an answer that differs) does not stop the script:
# the run is kept with its errors, as the article keeps them, and the report shows it as invalid.
rec() {
    local engine=$1 name=$2 purpose=$3 log rc=0 dir
    shift 3
    log=$(mktemp)
    bench/record.sh --area="$engine" --engine="$engine" --milestone=reproduce --client-cpus="$CLIENT_CPUS" \
        --run="$name" --purpose="$purpose" --scale="$SCALE_TEXT" -- "$@" 2>&1 | tee "$log" || rc=$?
    dir=$(sed -n 's/^record: //p' "$log" | tail -n 1)
    rm -f "$log"
    [ -n "$dir" ] && printf '%s\t%s\n' "$name" "$dir" >> "$RUNS"
    [ "$rc" = 0 ] || echo "reproduce.sh: run $name ended with status $rc (kept: $dir)"
    return 0
}
# folder of the newest run of a name ("" if there is none)
run_dir() { awk -F'\t' -v n="$1" '$1 == n {d = $2} END {print d}' "$RUNS"; }
# must NAME: the folder of a run that a later step needs, or stop with a clear message
must() { local d; d=$(run_dir "$1"); [ -n "$d" ] && [ -s "$d/$2" ] || die "no result of run $1 ($2): run the step that makes it first"; echo "$d/$2"; }

# drive ENGINE NAME PURPOSE WORKLOAD CLIENTS QUERIES [driver options]
# One latency run of bench/driver.py: for every query and client count a warm-up, then --iterations
# measured executions (at least two per client), every answer compared with the reference, every
# statement capped at $CAP seconds (a statement over the cap is recorded as a failure).
# Vertica is read with --client socket: the clock stops when the last byte of the answer has
# arrived, exactly as for ClickHouse (which the driver reads over HTTP).
drive() {
    local engine=$1 name=$2 purpose=$3 wl=$4 clients=$5 only=$6 client=""
    shift 6
    [ "$engine" = vertica ] && client="--client socket"
    rec "$engine" "$name" "$purpose" bash -c "python3 bench/driver.py run $client --workload $wl --var tenant=$TENANT --out \$BENCH_RUN_DIR/driver --clients $clients --iterations $ITER --warmup 1 --statement-cap $CAP --only $only $*"
}

# ---- engines and limits ----------------------------------------------------------------------
# With limits the engine runs inside a systemd scope with the CPUs and the memory of --cpus and
# --memory (bench/limits.sh). Without, it runs as it is.
vertica_ready() {
    if [ "$LIMITS" = yes ]; then
        bench/limits.sh status "${LIMIT_OPTS[@]}" --check > /dev/null 2>&1 || bench/limits.sh start "${LIMIT_OPTS[@]}" | tail -n 2
        bench/limits.sh status "${LIMIT_OPTS[@]}" --check | tail -n 1 || die "Vertica is not inside its limits (bench/limits.sh status)"
    else
        q "SELECT 1" > /dev/null 2>&1 || bench/limits.sh stop | tail -n 1    # "stop" = start without limits
        q "SELECT 1" > /dev/null || die "Vertica does not answer"
    fi
}
vertica_down() { bench/limits.sh halt | tail -n 1; }
clickhouse_ready() {
    if [ "$LIMITS" = yes ]; then
        bench/limits.sh start --engine=clickhouse "${LIMIT_OPTS[@]}" | tail -n 3
        bench/limits.sh status --engine=clickhouse "${LIMIT_OPTS[@]}" --check | tail -n 1 || return 1
    else
        bench/engines/clickhouse/server.sh start | tail -n 1
    fi
}
clickhouse_down() {
    if [ "$LIMITS" = yes ]; then bench/limits.sh halt --engine=clickhouse | tail -n 1
    else bench/engines/clickhouse/server.sh stop | tail -n 1; fi
}
deploy() {   # fenced | unfenced
    rec vertica "deploy-$1" "functions deployed $1" scripts/deploy.sh --fenced="$([ "$1" = fenced ] && echo yes || echo no)"
}

# ---- the query sets --------------------------------------------------------------------------
# IDs of bench/workloads/*.sql. A = native SQL, At = native rewritten, D / Dt = the same on the
# Database Designer copy, B / B+ = bitmap paths, Bpar = every-thread form, N = ClickHouse SQL,
# C = ClickHouse bitmaps.
HEAD=q1.count.Bplus,q1.ids.Bplus,q2.daily.B,q3.Bplus,q4.Bplus,q7.Bj,q7.Bplus,q8.Bplus    # the six questions
PAR=q3.Bplus,q3.Bpar,q7.Bplus,q7.Bpar                                                    # one pass / every thread
NATIVE=q1.count.A,q1.count.D,q1.ids.A,q1.ids.D,q2.daily.A,q2.daily.D,q3.A,q3.D,q4.A,q4.D,q7.A,q7.At,q7.D,q7.Dt,q8.A,q8.D
IDS_ROWS=q1.ids.Bplus,q4.Bplus,q8.Bplus,q1.ids.rowtext.Bplus,q4.rowtext.Bplus,q8.rowtext.Bplus,q1.ids.text.Bplus,q4.text.Bplus,q8.text.Bplus
IDS_USE=q1.ids.sum.Bplus,q4.sum.Bplus,q8.sum.Bplus,q8.join.Bplus,q8.join.Bpin,q8.agg.Bplus
IDS_SAVE=q8.save.set.Bplus,q8.save.ids.Bplus
LIVE=q1.count.Bplus,q3.Bplus,q8.Bplus
CH_HEAD=q1.count.N,q1.count.C,q1.ids.N,q1.ids.C,q2.daily.N,q2.daily.C,q3.N,q3.C,q4.N,q4.C,q7.N,q7.C,q8.N,q8.C
CH_IDS=q1.ids.N,q4.N,q8.N,q1.ids.C,q4.C,q8.C,q1.ids.sum.C,q4.sum.C,q8.sum.C,q8.join.C,q8.join.Cin,q8.agg.C
CH_SAVE=q8.save.set.C,q8.save.ids.C

# The row filter on a pinned set (q8.join.Bpin) needs the set in the memory of the node that
# filters the rows (docs/PINNED.md). On a database with several nodes the rows are filtered on
# every node, so that test is left out there; the semi-join (q8.join.Bplus) answers the same.
ids_use() {
    if [ "$(q "SELECT COUNT(*) FROM v_catalog.nodes")" -gt 1 ]; then echo "${IDS_USE/,q8.join.Bpin/}"; else echo "$IDS_USE"; fi
}

# ---- steps -----------------------------------------------------------------------------------
step_setup() {
    say "setup: library, expression tool, schema"
    make && make tools
    vertica_ready
    deploy fenced
    if [ "$(q "SELECT COUNT(*) FROM v_catalog.schemata WHERE schema_name = 'bitmap_demo'")" = 0 ]; then
        echo "creating schema bitmap_demo (sql/schema.sql, sql/access.sql)"
        "${VSQL[@]}" -f sql/schema.sql > /dev/null
        "${VSQL[@]}" -f sql/access.sql > /dev/null
    fi
}

step_data() {
    say "data: generator --$SIZE for tenant $TENANT"
    vertica_ready
    [ "$(q "SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT")" = 0 ] \
        || { echo "tenant $TENANT already has data: step skipped (cleanup removes it)"; return 0; }
    # the article's data: topics skewed (1.5), IDs dense and in sign-up order, seed 42
    rec vertica generate "generator --$SIZE: people, interests, events, devices, assets" \
        scripts/generate.sh --tenant="$TENANT" --snapshot=1 --"$SIZE" --topic-skew=1.5 --id-order=signup --id-space=dense
}

step_index() {
    say "index: build, validate, publish; bit slices; projections"
    vertica_ready
    if [ "$(q "SELECT COUNT(*) FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $TENANT AND domain = 'person' AND state = 'active'")" != 0 ]; then
        echo "tenant $TENANT has a published person index: builds skipped"
    else
        # the transform builder (runs fenced and unfenced); validation re-counts every set from the source
        rec vertica build-person "lifecycle build of the person index and the daily sets (transform builder), validated, published" \
            scripts/snapshot.sh build --tenant="$TENANT" --domain=person --snapshot=1 --source-snapshot=1 --watermark="$W" --daily --publish
        rec vertica build-device "lifecycle build of the device index, validated, published" \
            scripts/snapshot.sh build --tenant="$TENANT" --domain=device --snapshot=1 --source-snapshot=1 --watermark="$DW" --publish
        # the age as one set per bit: sums and counts of an attribute without a join
        rec vertica build-bitsliced "bit-sliced sets of the age added to the person snapshot" bench/bitsliced.sh add --tenant="$TENANT"
    fi
    # second projection of the index, sorted by chunk: expressions are evaluated chunk by chunk without a sort
    if [ "$(q "SELECT COUNT(*) FROM v_catalog.projections WHERE projection_schema = 'bitmap_demo' AND projection_name = 'bitmap_index_by_chunk'")" = 0 ]; then
        rec vertica projection-bychunk "index projection sorted by chunk created and refreshed" vsql -X -v ON_ERROR_STOP=1 -f bench/vertica_projection_bychunk.sql
    fi
    # hand-tuned projection of the profile table for the native queries (created once, then kept up to date by Vertica)
    rec vertica projection-native "hand-tuned native projection of the profiles (IF NOT EXISTS), refreshed" vsql -X -v ON_ERROR_STOP=1 -f bench/vertica_projections.sql
    rec vertica storage "bytes and rows per projection" bench/storage.sh
}

step_native() {
    say "native: Database Designer copy, native latency on hand-tuned and designed projections"
    vertica_ready
    local design="${DBD_SCHEMA}_design"
    # the workload of the comparison: every native query on bitmap_demo and on the copy, same answer group
    local mk="python3 bench/make_dbd_workload.py --workload bench/workloads/vertica.sql --var tenant=$TENANT --schema $DBD_SCHEMA --out-workload \$BENCH_RUN_DIR/dbd_workload.sql --out-queries \$BENCH_RUN_DIR/dbd_queries.sql"
    bench/dbd.sh drop --schema="$DBD_SCHEMA" --design="$design" > /dev/null 2>&1 || true
    rec vertica dbd-copy "copy of the source tables into $DBD_SCHEMA without projections" bench/dbd.sh copy --tenant="$TENANT" --schema="$DBD_SCHEMA"
    rec vertica dbd-design "Database Designer: comprehensive design for the native queries, deployed on the copy" \
        bash -c "$mk && bench/dbd.sh design --queries=\$BENCH_RUN_DIR/dbd_queries.sql --out=\$BENCH_RUN_DIR/dbd --schema=$DBD_SCHEMA --design=$design"
    # native statements take seconds to a minute under load: one measured execution per client is
    # enough at 32 clients, and the cap is three times the bitmap runs'
    rec vertica native "native SQL of the six questions on hand-tuned (A, At) and Database Designer (D, Dt) projections" \
        bash -c "$mk && python3 bench/driver.py run --client socket --workload \$BENCH_RUN_DIR/dbd_workload.sql --out \$BENCH_RUN_DIR/driver --clients $CLIENTS --iterations $ITER --min-per-client 1 --warmup 1 --statement-cap $((CAP * 3)) --only $NATIVE"
}

# Reference answers. The native oracle of every answer group runs once here; the latency runs then
# compare every execution with these answers (--expect) and do not run the oracles again
# (--skip-oracles), which at 100 M people take up to half an hour each.
step_check() {
    rec vertica check-headline "reference answers of the six questions: native oracles and bitmap paths" \
        bash -c "python3 bench/driver.py check --client socket --workload bench/workloads/vertica.sql --var tenant=$TENANT --out \$BENCH_RUN_DIR/driver --only $HEAD,q3.Bpar,q7.Bpar"
    rec vertica check-ids "reference answers of the ID-list tests" \
        bash -c "python3 bench/driver.py check --client socket --workload bench/workloads/vertica_ids.sql --var tenant=$TENANT --out \$BENCH_RUN_DIR/driver --only $IDS_ROWS,$(ids_use)"
}

bitmap_mode() {   # fenced | unfenced
    local m=$1 vcheck xids
    vcheck=$(must check-headline driver/check.csv); xids=$(must check-ids driver/check.csv)
    deploy "$m"
    drive vertica "headline-$m" "the six questions through the index, $m" bench/workloads/vertica.sql "$CLIENTS" "$HEAD" --expect "$vcheck" --skip-oracles
    drive vertica "par-$m" "facets and overlap: one pass (Bplus) and every thread (Bpar), $m" bench/workloads/vertica.sql "$CLIENTS" "$PAR" --expect "$vcheck" --skip-oracles
    drive vertica "ids-rows-$m" "ID lists sent to the client: INT rows, text rows, text blocks, $m" bench/workloads/vertica_ids.sql "$CLIENTS" "$IDS_ROWS" --expect "$xids" --skip-oracles
    drive vertica "ids-use-$m" "ID lists used inside the engine; join and row filter on the profile rows; bit-sliced totals, $m" bench/workloads/vertica_ids.sql "$CLIENTS" "$(ids_use)" --expect "$xids" --skip-oracles
    # the audience kept in the database, as a set and as a table of IDs: the targets are created anew, 1 client
    rec vertica "ids-save-setup-$m" "target tables of the save tests created anew (schema bitmap_bench)" vsql -X -q -v ON_ERROR_STOP=1 -f bench/vertica_idtests.sql
    drive vertica "ids-save-$m" "the audience saved as a set and as a table of IDs, 1 client, $m" bench/workloads/vertica_ids.sql 1 "$IDS_SAVE"
}

step_bitmap() {
    say "bitmap: reference answers, then fenced and unfenced"
    vertica_ready
    [ "$(ids_use)" = "$IDS_USE" ] || echo "several nodes: the row filter on a pinned set (q8.join.Bpin) is left out (docs/PINNED.md)"
    deploy fenced
    step_check
    bitmap_mode fenced
    bitmap_mode unfenced
    # The aggregate builder (unfenced only): groups the membership rows on every thread. It builds
    # a second snapshot from the same source, validates it, and the snapshot is discarded.
    # Its statement runs in a resource pool of its own (one statement at a time, --build-memory);
    # an existing pool of that name is used as it is.
    if [ "$(q "SELECT COUNT(*) FROM v_catalog.resource_pools WHERE name = 'bitmap_build'")" != 0 ] \
        || q "CREATE RESOURCE POOL bitmap_build MEMORYSIZE '0%' MAXMEMORYSIZE '$BUILD_MEM' PLANNEDCONCURRENCY 1"; then
        rec vertica build-aggregate "lifecycle build of a second person snapshot with the aggregate builder, validated" \
            scripts/snapshot.sh build --tenant="$TENANT" --domain=person --snapshot=next --source-snapshot=1 --watermark="$W" --daily --aggregate --pool=bitmap_build
        local s
        s=$(q "SELECT COALESCE(MAX(snapshot_id), 0) FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $TENANT AND domain = 'person' AND state <> 'active'")
        [ "$s" = 0 ] || scripts/snapshot.sh discard --tenant="$TENANT" --domain=person --snapshot="$s" | tail -n 1
    else
        echo "reproduce.sh: resource pool bitmap_build could not be created with MAXMEMORYSIZE $BUILD_MEM: the aggregate build is skipped (give --build-memory, a smaller size or a share such as 60%)"
    fi
    deploy fenced
}

step_refresh() {
    say "refresh: 1 % of the people changed, three ways of reporting it"
    vertica_ready
    # each test builds the new state in full and applies the batch incrementally (with validation),
    # compares the two results byte for byte, and removes everything it made
    rec vertica refresh-random-delta "refresh, 1 % random, changes reported as add/remove" bench/refresh.sh --tenant="$TENANT" --fraction=0.01 --spread=random --report=delta
    rec vertica refresh-recent-mixed "refresh, 1 % recent sign-ups (few chunks)" bench/refresh.sh --tenant="$TENANT" --fraction=0.01 --spread=recent --report=mixed
    rec vertica refresh-random-mixed "refresh, 1 % random, reported as 'this person changed'" bench/refresh.sh --tenant="$TENANT" --fraction=0.01 --spread=random --report=mixed
}

step_live() {
    say "live: the index as a live aggregate projection"
    vertica_ready
    if [ "$(q "SELECT COUNT(*) FROM v_catalog.schemata WHERE schema_name = 'bitmap_live'")" != 0 ] && [ "$REPLACE_LIVE" != yes ]; then
        die "schema bitmap_live exists: the step would drop it. Give --replace-live to allow that."
    fi
    local vcheck; vcheck=$(must check-headline driver/check.csv)
    deploy unfenced                       # the live index is made for the unfenced deployment
    scripts/live_index.sh drop > /dev/null 2>&1 || true
    rec vertica live-create "schema bitmap_live: tag and event tables with their live projections, empty" scripts/live_index.sh create
    rec vertica live-load "tag rows and events loaded; the projections build the sets inside the load" scripts/live_index.sh load --tenant="$TENANT" --watermark="$W"
    drive vertica live-headline "audience count, facets and ID rows on the live projection, unfenced" bench/workloads/vertica.sql "$CLIENTS" "$LIVE" --var index=bitmap_live.bitmap_index --expect "$vcheck" --skip-oracles
    # about 1 % more tag rows, spread over every chunk, prepared in a staging table (not measured)
    bench/live_append.sh batch --tenant="$TENANT" --residue=6
    # 32 clients query for 300 s (audience count 4 : facets 2); 60 s in, the rows are appended
    rec vertica live-append-under-load "live index under load: 32 clients query while 1 % more tag rows are appended" \
        bash -c "python3 bench/driver.py mixed --client socket --workload bench/workloads/vertica.sql --var tenant=$TENANT --var index=bitmap_live.bitmap_index --out \$BENCH_RUN_DIR/driver --clients 32 --duration 300 --warmup-s 30 --statement-cap $CAP --only q1.count.Bplus,q3.Bplus --weights q1.count.Bplus=4,q3.Bplus=2 --expect $vcheck --skip-oracles --background 'bench/live_append.sh append --tenant=$TENANT' --background-at 60"
    drive vertica live-headline-after-append "the same queries right after the append (sets stored in two pieces)" bench/workloads/vertica.sql "$CLIENTS" "$LIVE" --var index=bitmap_live.bitmap_index --expect "$vcheck" --skip-oracles
    rec vertica live-storage "containers, rows and bytes of the live projections" scripts/live_index.sh status
    deploy fenced
}

step_clickhouse() {
    say "clickhouse: the same rows, the same sets, the same questions"
    command -v clickhouse-client > /dev/null || die "clickhouse-client not found (bench/engines/clickhouse/VERSION names the packages)"
    local vcheck xids
    vcheck=$(must check-headline driver/check.csv); xids=$(must check-ids driver/check.csv)
    vertica_ready
    rec vertica export "the tenant's source tables written as TSV for ClickHouse" bench/ch.sh export --tenant="$TENANT" --dir="$EXPORT_DIR"
    # one engine at a time: Vertica stops, ClickHouse starts with the same CPUs and memory
    vertica_down
    # (the ClickHouse runs are named ch-...: a run name is used once in a record folder)
    if clickhouse_ready; then
        rec clickhouse ch-load "schema, load of the exported rows, OPTIMIZE FINAL" bench/ch.sh load --tenant="$TENANT" --dir="$EXPORT_DIR"
        rec clickhouse ch-build "groupBitmap sets per predicate, per day and channel, per device predicate" bench/ch.sh build --tenant="$TENANT" --watermark="$W" --device-watermark="$DW"
        rec clickhouse ch-build-bits "the bit-sliced sets of the age" bench/ch.sh build-bits --tenant="$TENANT"
        # every ClickHouse answer must equal Vertica's native answer (--expect: rows and SHA-256)
        drive clickhouse ch-headline "the six questions in ClickHouse: SQL (N) and bitmaps (C)" bench/workloads/clickhouse.sql "$CLIENTS" "$CH_HEAD" --expect "$vcheck"
        drive clickhouse ch-ids "ID lists in ClickHouse: delivered, used inside the engine, row filter and join, bit-sliced totals" bench/workloads/clickhouse_ids.sql "$CLIENTS" "$CH_IDS" --expect "$xids"
        rec clickhouse ch-ids-save-setup "target tables of the save tests created anew (database xbench)" \
            bash -c "clickhouse-client --host ::1 --port 9000 --multiquery < bench/engines/clickhouse/idtests.sql"
        drive clickhouse ch-ids-save "the audience saved as a set and as a table of IDs, 1 client" bench/workloads/clickhouse_ids.sql 1 "$CH_SAVE"
        rec clickhouse ch-storage "rows and bytes per ClickHouse table" bench/ch.sh storage
    else
        echo "reproduce.sh: ClickHouse did not start: its runs are skipped"
    fi
    # whatever happened above, ClickHouse stops and Vertica comes back
    clickhouse_down || true
    vertica_ready
}

step_report() {
    say "report"
    local out="$REC/REPORT.md" dirs=() name dir
    # the newest folder of every run name, in the order the runs were first made
    while IFS=$'\t' read -r name; do
        dir=$(run_dir "$name")
        [ -s "$dir/driver/summary.csv" ] && dirs+=("$dir")
    done < <(awk -F'\t' '!seen[$1]++ {print $1}' "$RUNS")
    [ ${#dirs[@]} -gt 0 ] || die "no latency run recorded yet in $REC"
    python3 bench/report.py "${dirs[@]}" --title "Bitmap benchmark, $SCALE_TEXT" --out "$out"
    {
        echo; echo "## Builds, refresh, load and append"; echo
        echo "Summary lines of the runs that are not latency runs (the newest of each name):"; echo
        echo '```'
        while IFS=$'\t' read -r name; do
            dir=$(run_dir "$name")
            [ -s "$dir/driver/summary.csv" ] && continue
            [ -s "$dir/summary.txt" ] && sed "s/^/$name: /" "$dir/summary.txt"
        done < <(awk -F'\t' '!seen[$1]++ {print $1}' "$RUNS")
        echo '```'
    } >> "$out"
    echo "report written: $out"
}

step_finish() {
    say "finish: fenced deployment; Vertica without limits"
    vertica_ready
    deploy fenced
    [ "$LIMITS" = no ] || bench/limits.sh stop | tail -n 1
}

step_cleanup() {
    say "cleanup: tenant $TENANT, Designer copy, scratch schema, exported files"
    q "SELECT 1" > /dev/null || die "Vertica does not answer"
    local t
    for t in bitmap_index bitmap_predicate daily_bitmap bitmap_snapshot bitmap_change bitmap_family \
             user_profile user_interest event_log device_state asset_state asset_source gen_person bitmap_reader; do
        q "DELETE FROM bitmap_demo.$t WHERE tenant_id = $TENANT; COMMIT;" > /dev/null || true
    done
    q "SELECT PURGE_TABLE('bitmap_demo.bitmap_index'); SELECT PURGE_TABLE('bitmap_demo.user_interest'); SELECT PURGE_TABLE('bitmap_demo.event_log'); SELECT PURGE_TABLE('bitmap_demo.user_profile');" > /dev/null || true
    bench/dbd.sh drop --schema="$DBD_SCHEMA" --design="${DBD_SCHEMA}_design" > /dev/null 2>&1 || true
    q "DROP SCHEMA IF EXISTS bitmap_bench CASCADE" > /dev/null 2>&1 || true
    rm -rf "${EXPORT_DIR:?}/t$TENANT"
    echo "removed. Schema bitmap_live (step live), the resource pool bitmap_build and the ClickHouse database are left as they are; the run folders stay in $REC."
}

# ---- main ------------------------------------------------------------------------------------
for s in "${STEPS[@]}"; do
    case "$s" in
        all) step_setup; step_data; step_index; step_native; step_bitmap; step_refresh; step_clickhouse; step_report; step_finish ;;
        setup|data|index|native|bitmap|refresh|live|clickhouse|report|finish|cleanup) "step_$s" ;;
        *) die "unknown step: $s (see --help)" ;;
    esac
done
echo
echo "reproduce.sh: done. Run folders and REPORT.md: $REC"

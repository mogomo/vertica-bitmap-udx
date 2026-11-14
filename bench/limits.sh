#!/usr/bin/env bash
# CPU and memory limits for the engine under test (decision D9; fairness rules of the benchmark).
#
#   bench/limits.sh start  [--engine=vertica] [--cpus=0-19] [--memory=56G] [--pool-memory=50G]
#                          [--planned-concurrency=20]
#   bench/limits.sh stop   [--engine=vertica]
#   bench/limits.sh status [--engine=vertica] [--check]
#   bench/limits.sh halt   [--engine=vertica]
# Engines: vertica, clickhouse. status --check also fails if the other engine has a process
# running (one engine at a time). halt restores the defaults and leaves the engine stopped.
#
# start   stops the engine, gives the engine's own memory and concurrency settings values that fit
#         the limit, and starts the engine inside the transient systemd scope vbitmap-engine.scope
#         with AllowedCPUs, MemoryMax and MemorySwapMax=0. Then it checks that every server
#         process is in the scope.
# stop    stops the engine, restores its default settings and starts it again without limits.
# status  one key=value line per fact: the scope's cgroup files, every server process with its
#         cgroup and allowed CPUs, the engine's own settings. With --check the exit status is 1
#         unless the scope is active with the limits and every server process is inside it.
#
# Vertica (checked on 26.3.0-2): admintools started inside the scope starts spread, vertica and
# vertica-udx-zygote inside it, so no process has to be moved afterwards. The cpuset binds every
# thread, but Vertica still sizes itself from the whole machine (host_resources reports every core
# and all memory). The GENERAL pool therefore gets MAXMEMORYSIZE (below memory.max, room left for
# the catalog, fenced UDx processes and page cache) and PLANNEDCONCURRENCY = number of CPUs. Both
# take effect only when the database restarts (manual, ALTER RESOURCE POOL), which start and stop
# do. EXECUTIONPARALLELISM cannot be set on GENERAL and stays AUTO (one thread per core of the
# machine). Needs passwordless sudo for systemd-run. Database name: VSQL_DATABASE.
# ClickHouse: the benchmark's own instance (bench/engines/clickhouse/server.sh) in the folder CH_HOME
# (default /data/xbench/clickhouse).
set -euo pipefail

cd "$(dirname "$0")/.."

UNIT=vbitmap-engine
CMD="${1:-}"
[ $# -gt 0 ] && shift
ENGINE=vertica; CPUS=0-19; MEM=56G; POOL_MEM=50G; PLANNED=20; CHECK=no
for arg in "$@"; do
    case "$arg" in
        --engine=*)              ENGINE="${arg#*=}" ;;
        --cpus=*)                CPUS="${arg#*=}" ;;
        --memory=*)              MEM="${arg#*=}" ;;
        --pool-memory=*)         POOL_MEM="${arg#*=}" ;;
        --planned-concurrency=*) PLANNED="${arg#*=}" ;;
        --check)                 CHECK=yes ;;
        -h|--help)               sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "limits.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[[ "$CPUS" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || { echo "limits.sh: bad --cpus" >&2; exit 2; }
[[ "$MEM" =~ ^[0-9]+[KMGT]$ && "$POOL_MEM" =~ ^[0-9]+[KMGT]$ ]] || { echo "limits.sh: --memory and --pool-memory: number with K, M, G or T" >&2; exit 2; }
[[ "$PLANNED" =~ ^[0-9]+$ ]] || { echo "limits.sh: bad --planned-concurrency" >&2; exit 2; }
MEM_BYTES=$(numfmt --from=iec "$MEM")
[ "$(numfmt --from=iec "$POOL_MEM")" -lt "$MEM_BYTES" ] || { echo "limits.sh: --pool-memory must be below --memory" >&2; exit 2; }
CG=/sys/fs/cgroup/system.slice/$UNIT.scope

# ---- Vertica ---------------------------------------------------------------------------------
VT=/opt/vertica/bin
vertica_db() { echo "${VSQL_DATABASE:?limits.sh: set VSQL_DATABASE}"; }
vertica_pids() { pgrep -f '^/opt/vertica/(spread/sbin/spread|bin/vertica)' || true; }   # incl. fenced UDx processes
vertica_up() { "$VT/admintools" -t db_status -s UP 2>/dev/null | grep -qx "$(vertica_db)"; }
vertica_sql() { "$VT/vsql" -X -A -t -q -v ON_ERROR_STOP=1 -c "$1"; }
vertica_stop() {
    if vertica_up; then "$VT/admintools" -t stop_db -d "$(vertica_db)" | tail -n 1; fi
    local i
    for i in $(seq 1 60); do [ -z "$(vertica_pids)" ] && return 0; sleep 1; done
    echo "limits.sh: Vertica processes still running after stop: $(vertica_pids | tr '\n' ' ')" >&2; return 1
}
vertica_start_cmd() { echo "$VT/admintools -t start_db -d $(vertica_db)"; }
vertica_set_pool() {   # limited | default (needs a running database; effective after restart)
    if [ "$1" = limited ]; then
        vertica_sql "ALTER RESOURCE POOL general MAXMEMORYSIZE '$POOL_MEM' PLANNEDCONCURRENCY $PLANNED;"
    else
        vertica_sql "ALTER RESOURCE POOL general MAXMEMORYSIZE DEFAULT PLANNEDCONCURRENCY DEFAULT;"
    fi
}
vertica_settings() {
    vertica_up || { echo "vertica_state=down"; return 0; }
    vertica_sql "SELECT 'vertica_version=' || REPLACE(VERSION(), ' ', '_')"
    vertica_sql "SELECT 'pool_general_maxmemorysize=' || REPLACE(maxmemorysize, ' ', '_')
                     || ' pool_general_plannedconcurrency=' || plannedconcurrency
                     || ' pool_general_executionparallelism=' || executionparallelism
                 FROM resource_pools WHERE name = 'general'"
    vertica_sql "SELECT 'pool_general_max_memory_kb=' || max_memory_size_kb || ' pool_general_planned_concurrency=' || planned_concurrency
                     || ' pool_general_query_budget_kb=' || query_budget_kb
                 FROM resource_pool_status WHERE pool_name = 'general'"
    vertica_sql "SELECT 'host_cores=' || processor_core_count || ' host_memory_mb=' || total_memory_bytes // 1048576
                 FROM host_resources"
}

# ---- ClickHouse (own instance: bench/engines/clickhouse/server.sh) ------------------------------
# Inside the scope ClickHouse reads its CPU and memory from the cgroup; the limits are also set
# explicitly so that both engines get the same numbers: max_server_memory_usage = --pool-memory
# (Vertica's GENERAL pool) and max_threads = number of CPUs of --cpus.
CHS=bench/engines/clickhouse/server.sh
CH_HOME="${CH_HOME:-/data/xbench/clickhouse}"
clickhouse_pids() { "$CHS" pids; }
clickhouse_up() { "$CHS" up; }
clickhouse_stop() { "$CHS" stop; }
clickhouse_start_cmd() { echo "$PWD/$CHS start"; }
cpu_count() { local n=0 r a b; for r in ${CPUS//,/ }; do a=${r%-*}; b=${r#*-}; n=$((n + b - a + 1)); done; echo $n; }
clickhouse_set_pool() {   # limited | default (files read at server start)
    local c="$CH_HOME/config/config.d/limits.xml" u="$CH_HOME/config/users.d/limits.xml"
    mkdir -p "$(dirname "$c")" "$(dirname "$u")"
    if [ "$1" = limited ]; then
        echo "<clickhouse><max_server_memory_usage>$(numfmt --from=iec "$POOL_MEM")</max_server_memory_usage></clickhouse>" > "$c"
        echo "<clickhouse><profiles><default><max_threads>$(cpu_count)</max_threads></default></profiles></clickhouse>" > "$u"
    else
        rm -f "$c" "$u"
    fi
}
clickhouse_settings() {
    clickhouse_up || { echo "clickhouse_state=down"; return 0; }
    curl -s "http://[::1]:8123/" --data-binary "SELECT 'clickhouse_version=' || version()
        || ' max_server_memory_usage=' || (SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage')
        || ' max_threads=' || toString(getSetting('max_threads'))
        FORMAT TSVRaw" 2>/dev/null || echo "clickhouse_settings=unreadable"
}

case "$ENGINE" in
    vertica)    OTHER=clickhouse ;;
    clickhouse) OTHER=vertica ;;
    *) echo "limits.sh: engine $ENGINE is not supported" >&2; exit 2 ;;
esac
pids()        { "${ENGINE}_pids"; }
stop_engine() { "${ENGINE}_stop"; }

status() {
    local ok=yes p cg cpus
    if systemctl is-active --quiet "$UNIT.scope"; then
        echo "scope=$UNIT.scope active=yes cgroup=${CG#/sys/fs/cgroup}"
        echo "cpuset_cpus_effective=$(cat "$CG/cpuset.cpus.effective") memory_max=$(cat "$CG/memory.max") memory_swap_max=$(cat "$CG/memory.swap.max")"
        echo "memory_current=$(cat "$CG/memory.current") memory_peak=$(cat "$CG/memory.peak") $(awk '{printf "cpu_%s=%s ", $1, $2}' "$CG/cpu.stat")"
        [ "$(cat "$CG/cpuset.cpus.effective")" = "$CPUS" ] || { echo "check: cpuset is not $CPUS"; ok=no; }
        [ "$(cat "$CG/memory.max")" = "$MEM_BYTES" ] || { echo "check: memory.max is not $MEM_BYTES"; ok=no; }
        [ "$(cat "$CG/memory.swap.max")" = 0 ] || { echo "check: memory.swap.max is not 0"; ok=no; }
    else
        echo "scope=$UNIT.scope active=no"; ok=no
    fi
    local n=0
    for p in $(pids); do
        cg=$(cut -d: -f3 "/proc/$p/cgroup" 2>/dev/null) || continue
        cpus=$(awk '/^Cpus_allowed_list/ {print $2}' "/proc/$p/status")
        echo "pid=$p comm=$(cat "/proc/$p/comm") cgroup=$cg cpus_allowed=$cpus threads=$(awk '/^Threads/ {print $2}' "/proc/$p/status")"
        [ "$cg" = "${CG#/sys/fs/cgroup}" ] || { echo "check: pid $p is outside the scope"; ok=no; }
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || { echo "check: no $ENGINE server process"; ok=no; }
    # One engine at a time (isolation rule): the other engine must have no process at all.
    local o; o=$("${OTHER}_pids" | tr '\n' ' ')
    if [ -n "${o// /}" ]; then echo "check: $OTHER is running (pids $o)"; ok=no; else echo "other_engine=$OTHER state=down"; fi
    "${ENGINE}_settings"
    echo "limits_ok=$ok"
    [ "$CHECK" = no ] || [ "$ok" = yes ]
}

case "$CMD" in
    start)
        "${ENGINE}_up" || $("${ENGINE}_start_cmd") | tail -n 1   # settings are changed while it runs
        "${ENGINE}_set_pool" limited
        stop_engine
        if systemctl is-active --quiet "$UNIT.scope"; then
            echo "limits.sh: $UNIT.scope is still active with other processes: $(cat "$CG/cgroup.procs" | tr '\n' ' ')" >&2; exit 1
        fi
        # shellcheck disable=SC2046
        sudo systemd-run --scope --quiet --unit="$UNIT" --uid="$(id -u)" --gid="$(id -g)" \
            -p AllowedCPUs="$CPUS" -p MemoryMax="$MEM" -p MemorySwapMax=0 \
            -E HOME="$HOME" -E PATH="$PATH" -E CH_HOME="$CH_HOME" $( [ -n "${VSQL_DATABASE:-}" ] && echo "-E VSQL_DATABASE=$VSQL_DATABASE" ) \
            $("${ENGINE}_start_cmd") | tail -n 1
        CHECK=yes
        status ;;
    stop)
        "${ENGINE}_up" || $("${ENGINE}_start_cmd") | tail -n 1
        "${ENGINE}_set_pool" default
        stop_engine
        # started from this shell, as the engine was before any limit was set
        $("${ENGINE}_start_cmd") | tail -n 1
        "${ENGINE}_settings" ;;
    halt)
        # default settings, then the engine stays down (to measure the other engine alone)
        if [ "$ENGINE" = vertica ]; then
            vertica_up || $(vertica_start_cmd) | tail -n 1
            vertica_set_pool default
        else
            clickhouse_set_pool default
        fi
        stop_engine
        echo "halted=$ENGINE" ;;
    status)
        status ;;
    *)  sed -n '2,30p' "$0"; exit 2 ;;
esac

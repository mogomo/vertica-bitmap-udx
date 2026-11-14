#!/usr/bin/env bash
# Runs one command as a recorded benchmark run.
#
#   bench/record.sh --area=AREA --run=NAME [--milestone=M5a] [--purpose=TEXT] [--scale=TEXT]
#                   [--path=TEXT] [--engine=vertica] [--client-cpus=20,21] [--interval=1]
#                   -- COMMAND [ARG ...]
#
# Creates $BITMAP_RECORD_DIR/AREA/YYYY-MM-DD_NAME/ (default ~/bitmap_record; a run never reuses a
# folder: _2, _3 ... are appended) and writes there:
#   command.txt       command line, working directory, start and end (UTC), exit status
#   environment.txt   kernel, OS, CPU, memory, CPU frequency governors, engine and library
#                     versions, tool versions
#   repo.sha256       checksum of every repository file the run could use (code and SQL)
#   limits_before.txt bench/limits.sh status before the command, limits_after.txt after it
#   console.log       everything the command printed (also shown on the terminal)
#   samples.csv       every --interval seconds: memory and CPU time of the engine's cgroup, busy
#                     share of each client CPU, Unix time
#   summary.txt       the summary lines of the command ("word: key=value ..." lines)
#   meta.txt          key=value: duration, exit status, engine CPU time and memory peak, client
#                     CPU use, and validity (invalid if the command failed, the engine was not
#                     inside its limits, or a client CPU was saturated)
#   index_row.md      the row for benchmark_record/INDEX.md
# The command runs pinned to the client CPUs (taskset), outside the engine's limits, with the
# folder in BENCH_RUN_DIR. The folder is printed last ("record: <folder>").
set -uo pipefail

cd "$(dirname "$0")/.."
REPO=$(pwd)

AREA=""; RUN=""; MILESTONE=M5a; PURPOSE=""; SCALE=""; RPATH=""; ENGINE=vertica; CLIENT_CPUS=20,21; INTERVAL=1
while [ $# -gt 0 ]; do
    case "$1" in
        --area=*)        AREA="${1#*=}" ;;
        --run=*)         RUN="${1#*=}" ;;
        --milestone=*)   MILESTONE="${1#*=}" ;;
        --purpose=*)     PURPOSE="${1#*=}" ;;
        --scale=*)       SCALE="${1#*=}" ;;
        --path=*)        RPATH="${1#*=}" ;;
        --engine=*)      ENGINE="${1#*=}" ;;
        --client-cpus=*) CLIENT_CPUS="${1#*=}" ;;
        --interval=*)    INTERVAL="${1#*=}" ;;
        --)              shift; break ;;
        -h|--help)       sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "record.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
[ $# -gt 0 ] || { echo "record.sh: no command (put it after --)" >&2; exit 2; }
[[ "$AREA" =~ ^[a-z0-9_-]+$ && "$RUN" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "record.sh: --area and --run are required (letters, digits, - _ .)" >&2; exit 2; }
[[ "$CLIENT_CPUS" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "record.sh: --client-cpus is a comma-separated CPU list" >&2; exit 2; }

ROOT="${BITMAP_RECORD_DIR:-$HOME/bitmap_record}"
base="$ROOT/$AREA/$(date +%F)_$RUN"; OUT="$base"; i=2
while [ -e "$OUT" ]; do OUT="${base}_$i"; i=$((i + 1)); done
mkdir -p "$OUT" || exit 1

# the recorder and the command run on the client CPUs
taskset -cp "$CLIENT_CPUS" $$ > /dev/null || { echo "record.sh: taskset failed" >&2; exit 1; }
IFS=',' read -r -a CCPUS <<< "$CLIENT_CPUS"

# ---- environment -----------------------------------------------------------------------------
{
    echo "kernel=$(uname -r) machine=$(uname -m)"
    echo "os=$(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "cpu=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo) logical_cpus=$(nproc --all)"
    echo "memory_total_kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo) swap_total_kb=$(awk '/^SwapTotal/ {print $2}' /proc/meminfo)"
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        printf '%s=%s/%s ' "${c##*/}" "$(cat "$c/cpufreq/scaling_governor" 2>/dev/null || echo na)" "$(cat "$c/cpufreq/scaling_max_freq" 2>/dev/null || echo na)"
    done; echo
    echo "load_before=$(cut -d' ' -f1-3 /proc/loadavg)"
    echo "python=$(python3 -V 2>&1 | cut -d' ' -f2) bash=${BASH_VERSION}"
    if [ "$ENGINE" = vertica ]; then
        vsql -X -A -t -q -c "SELECT 'vertica=' || VERSION()" 2>&1
        vsql -X -A -t -q -c "SELECT 'vbitmap=' || vbitmap.bm_version()" 2>&1
        vsql -X -A -t -q -c "SELECT 'vbitmap_functions=' || COUNT(*) || ' fenced=' || SUM(CASE WHEN is_fenced THEN 1 ELSE 0 END)
                             FROM user_functions WHERE schema_name = 'vbitmap'" 2>&1
    elif [ "$ENGINE" = clickhouse ]; then
        echo "clickhouse_binary=$(clickhouse --version 2>&1 | head -1)"
        curl -s "http://[::1]:8123/" --data-binary "SELECT 'clickhouse=' || version() || ' max_threads=' || toString(getSetting('max_threads')) FORMAT TSVRaw" 2>&1 \
            || echo "clickhouse=down"
    fi
} > "$OUT/environment.txt"
( cd "$REPO" && find Makefile bench scripts sql src tools tests/sql -type f 2>/dev/null | sort | xargs sha256sum ) > "$OUT/repo.sha256"
REPO_HASH=$(sha256sum < "$OUT/repo.sha256" | cut -c1-16)

bench/limits.sh status --engine="$ENGINE" > "$OUT/limits_before.txt" 2>&1
LIMITS_OK=$(sed -n 's/^limits_ok=//p' "$OUT/limits_before.txt")
CG=$(sed -n 's/^scope=.* active=yes cgroup=//p' "$OUT/limits_before.txt")
[ -n "$CG" ] && CG="/sys/fs/cgroup$CG"

# ---- sampler ---------------------------------------------------------------------------------
cpu_busy_idle() {   # cpuN: "busy idle" jiffies
    awk -v c="$1" '$1 == c {b = $2 + $3 + $4 + $7 + $8 + $9; i = $5 + $6; print b, i}' /proc/stat
}
cg_cpu_usec() { [ -n "$CG" ] && awk '$1 == "usage_usec" {print $2}' "$CG/cpu.stat" 2>/dev/null || echo 0; }
cg_mem()      { [ -n "$CG" ] && cat "$CG/memory.current" 2>/dev/null || echo 0; }
declare -A B0 I0
for c in "${CCPUS[@]}"; do read -r B0[$c] I0[$c] <<< "$(cpu_busy_idle "cpu$c")"; done
CPU0=$(cg_cpu_usec)

sampler() {
    local t0 now c b i pb pi line
    declare -A PB PI
    for c in "${CCPUS[@]}"; do read -r PB[$c] PI[$c] <<< "$(cpu_busy_idle "cpu$c")"; done
    t0=$(date +%s.%N)
    header="t_s,engine_memory_bytes,engine_cpu_usec"
    for c in "${CCPUS[@]}"; do header+=",cpu${c}_busy_pct"; done
    header+=",unix_s"
    echo "$header"
    while sleep "$INTERVAL"; do
        now=$(date +%s.%N)
        line="$(printf '%.2f' "$(echo "$now - $t0" | bc)"),$(cg_mem),$(cg_cpu_usec)"
        for c in "${CCPUS[@]}"; do
            read -r b i <<< "$(cpu_busy_idle "cpu$c")"
            line+=",$(awk -v db=$((b - PB[$c])) -v di=$((i - PI[$c])) 'BEGIN {printf "%.1f", (db + di) ? 100 * db / (db + di) : 0}')"
            PB[$c]=$b; PI[$c]=$i
        done
        echo "$line,$now"
    done
}
sampler > "$OUT/samples.csv" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT

# ---- the command -----------------------------------------------------------------------------
{
    printf 'command='; printf '%q ' "$@"; echo
    echo "cwd=$(pwd)"
    echo "start_utc=$(date -u +%FT%TZ)"
} > "$OUT/command.txt"
T0=$(date +%s.%N)
export BENCH_RUN_DIR="$OUT"   # the command may write its own files there (bench/driver.py --out)
"$@" 2>&1 | tee "$OUT/console.log"
STATUS=${PIPESTATUS[0]}
T1=$(date +%s.%N)
CPU1=$(cg_cpu_usec)
declare -A B1 I1
for c in "${CCPUS[@]}"; do read -r B1[$c] I1[$c] <<< "$(cpu_busy_idle "cpu$c")"; done
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
{ echo "end_utc=$(date -u +%FT%TZ)"; echo "exit_status=$STATUS"; } >> "$OUT/command.txt"

bench/limits.sh status --engine="$ENGINE" > "$OUT/limits_after.txt" 2>&1
grep -E '^[a-z_]+: [A-Za-z0-9_]+=' "$OUT/console.log" > "$OUT/summary.txt"

# ---- meta and validity -----------------------------------------------------------------------
DUR=$(echo "$T1 - $T0" | bc)
# Client CPU use over the whole run; saturation (90 % or more on one client CPU) is judged only on
# runs of at least 5 s (the counters tick every 10 ms and the recorder's own start is included).
client=""; saturated=no
for c in "${CCPUS[@]}"; do
    pct=$(awk -v db=$((B1[$c] - B0[$c])) -v di=$((I1[$c] - I0[$c])) 'BEGIN {printf "%.1f", (db + di) ? 100 * db / (db + di) : 0}')
    client+=" client_cpu${c}_busy_pct=$pct"
    awk -v p="$pct" 'BEGIN {exit !(p >= 90)}' && saturated=yes
done
awk -v d="$DUR" 'BEGIN {exit !(d < 5)}' && saturated="na (run shorter than 5 s)"

mem_peak_sampled=$(awk -F, 'NR > 1 && $2 > m {m = $2} END {print m + 0}' "$OUT/samples.csv")
reasons=()
[ "$STATUS" = 0 ] || reasons+=("exit status $STATUS")
[ "$LIMITS_OK" = yes ] || reasons+=("engine not inside its limits")
[ "$(sed -n 's/^limits_ok=//p' "$OUT/limits_after.txt")" = yes ] || [ "$LIMITS_OK" != yes ] || reasons+=("limits lost during the run")
[ "$saturated" != yes ] || reasons+=("client CPU saturated")
if [ ${#reasons[@]} -eq 0 ]; then validity=valid; else validity="invalid: $(IFS=';'; echo "${reasons[*]}")"; fi
{
    echo "area=$AREA run=$RUN folder=$(basename "$OUT") milestone=$MILESTONE engine=$ENGINE"
    echo "duration_s=$(printf '%.2f' "$DUR") exit_status=$STATUS repo_hash=$REPO_HASH"
    echo "engine_cpu_s=$(awk -v a="$CPU0" -v b="$CPU1" 'BEGIN {printf "%.1f", (b - a) / 1e6}') engine_memory_peak_sampled_bytes=$mem_peak_sampled engine_memory_peak_since_start_bytes=$( [ -n "$CG" ] && cat "$CG/memory.peak" 2>/dev/null || echo na)"
    echo "client_cpus=$CLIENT_CPUS$client client_saturated=${saturated// /_}"
    echo "limits_ok=${LIMITS_OK:-no}"
    echo "validity=$validity"
} > "$OUT/meta.txt"

result=$(tail -n 1 "$OUT/summary.txt" 2>/dev/null)
[ -n "$result" ] || result="duration $(printf '%.1f' "$DUR") s"
if [ "$validity" = valid ]; then v=valid; else v="invalid (${validity#invalid: })"; fi
echo "| ? | $(date +%F) | $MILESTONE | ${PURPOSE:-$RUN} | ${SCALE:-} | ${RPATH:-$ENGINE} | $result | $v | $AREA/$(basename "$OUT") |" > "$OUT/index_row.md"

cat "$OUT/meta.txt"
echo "record: $OUT"
exit "$STATUS"

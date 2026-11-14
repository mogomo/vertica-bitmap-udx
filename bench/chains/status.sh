#!/usr/bin/env bash
# One-shot progress report of the measurement chains (run on the workstation: ~/bitmap_record/status.sh).
#
# Rules of this script:
#   - It reads files only, as long as they show progress: no connection to the engine under test
#     (a monitoring query adds load to a measured run and can take catalog locks).
#   - It is cheap: one ps, a few stat calls, the bytes added to two log files since the previous
#     call, three small /sys files; about 0.1 s, on the client CPUs (20-21), not on the engine's.
#   - Progress is judged from evidence of work done, never from CPU use.
#
# Evidence (compared with the previous call, kept in .status_state):
#   run       what the open run has written: queries checked (driver/plans), executions measured
#             (rows of driver/raw.csv), console lines (phases of builds and refreshes)
#   requests  Vertica's own Data Collector file RequestsCompleted_*.log (written by the server within
#             seconds of each finished statement): statements finished and rows they processed
#   log       what statement threads added to vertica.log (Init Session: plans, transactions;
#             EEcmdq / EEThread: sort merge phases, storage containers written), shown as text: the
#             newest three kinds of line with their last time. Housekeeping threads (epochs,
#             heartbeat, tuple mover, schedulers) are left out: they write while the server idles.
# Information only, never a proof of progress: CPU seconds and bytes read/written of the engine's
# cgroup since the previous call.
#
# Escalation, only when none of the evidence above changed for STALL_MIN minutes (default 6), i.e.
# inside one long statement or a hang: the script then asks the engine twice, PROBE_GAP seconds
# apart (default 45), for the rows handled so far by the running statements (Vertica:
# execution_engine_profiles; ClickHouse: system.processes). Rows moved = a long but healthy
# statement, and the clock starts again; rows frozen or no statement running = STALL. Every probe
# is written to monitor.log with its time and duration, so a measured block that overlaps one can
# be found afterwards.
#
#   state=running  evidence changed within the last STALL_MIN minutes, or the probe saw rows move
#   state=STALL    reason=frozen: no file evidence for STALL_MIN minutes and the probe saw no rows
#                  move (engine_dead=yes: the cgroup also used no CPU and no I/O);
#                  reason=block: the run itself wrote nothing for BLOCK_MIN minutes (default 30)
#                  although the server works (one client may hang while the others keep the load up)
#   state=idle     no run open;  state=done  the last chain wrote ALL_DONE
cd ~/bitmap_record || exit 1
taskset -cp 20,21 $$ > /dev/null 2>&1
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=${VSQL_DATABASE:-VDB}
STALL_MIN=${STALL_MIN:-6}; BLOCK_MIN=${BLOCK_MIN:-30}; PROBE_GAP=${PROBE_GAP:-45}
STATE=.status_state
now=$(date +%s)
procs=$(ps -eo args)
chains=$(grep -oE 'run_chain[0-9]+b?\.sh' <<< "$procs" | sort -u | tr '\n' ' ')
run=$(grep -oE 'record\.sh --area=[a-z]+ .*--run=[^ ]+' <<< "$procs" | grep -oE -- '--run=[^ ]+' | head -n 1 | cut -d= -f2)
echo "time=$(date -u '+%F %T')Z chains=[${chains% }] run=${run:-none}"

if [ -z "$run" ]; then
    state=idle
    last=$(ls -t last_run*.log 2>/dev/null | sed -n 1p)
    [ -n "$last" ] && grep -q ALL_DONE "$last" 2>/dev/null && state=done
    rm -f "$STATE"
    echo "state=$state"
    exit 0
fi

# previous call: time, time of the last evidence, time of the last change of the run's files, run
# evidence, DC file, DC offset, server log size, CPU usec, I/O bytes
p_at=$now; p_changed=$now; p_runchanged=$now; p_run=""; p_dc=""; p_off=0; p_log=-1; p_cpu=0; p_io=0
[ -f "$STATE" ] && IFS='|' read -r p_at p_changed p_runchanged p_run p_dc p_off p_log p_cpu p_io < "$STATE"
since=$(( now - p_at ))

# ---- the run's own files
dir=$(ls -dt vertica/*_"$run" clickhouse/*_"$run" 2>/dev/null | head -n 1)
age=$(( (now - $(stat -c %Y "$dir/command.txt")) / 60 ))
plans=$(ls "$dir/driver/plans" 2>/dev/null | wc -l)
execs=0; [ -s "$dir/driver/raw.csv" ] && execs=$(( $(wc -l < "$dir/driver/raw.csv") - 1 ))
console=$(wc -l < "$dir/console.log" 2>/dev/null || echo 0)
runsig="$run/$plans/$execs/$console"
echo "run: age_min=$age queries_checked=$plans executions_measured=$execs console_lines=$console"
tail -n 1 "$dir/console.log" 2>/dev/null | cut -c1-200

# ---- the server's own files (no connection)
finished=0; rows=0; work=0; phases=""; dc=""; off=0; log=0; engine=none; logfile=""
case "$dir" in
vertica/*)
    engine=vertica
    cat_dir=$(ls -d ~/VDB/v_*_catalog 2>/dev/null | head -n 1)
    dc=$(ls -t "$cat_dir"/DataCollector/RequestsCompleted_*.log 2>/dev/null | head -n 1)
    if [ -n "$dc" ]; then
        off=$(stat -c %s "$dc")
        from=0; [ "$dc" = "$p_dc" ] && [ "$off" -ge "$p_off" ] && from=$p_off
        if [ -n "$p_dc" ]; then   # the first call only records the offset
            read -r finished rows < <(tail -c +$(( from + 1 )) "$dc" | head -c $(( off - from )) |
                awk -F: '/^:DCRequestsCompleted/ {n++} /^processed_row_count:/ {r += $2} END {print n + 0, r + 0}')
        fi
    fi
    logfile=$cat_dir/vertica.log
    log=$(stat -c %s "$logfile" 2>/dev/null || echo 0)
    if [ "$p_log" -ge 0 ]; then
        from=$p_log; [ "$log" -lt "$from" ] && from=0                       # rotated
        [ $(( log - from )) -gt 8388608 ] && from=$(( log - 8388608 ))      # at most 8 MB per call
        # what the statement threads wrote: the newest three kinds of line, each with the time of its
        # last occurrence and how often it came (content to judge by, e.g. "final merge phase")
        phases=$(tail -c +$(( from + 1 )) "$logfile" | head -c $(( log - from )) |
                 grep -a -E '^[0-9-]+ [0-9:.]+ (Init Session|EEcmdq|EEThread):' |
                 awk '{t = substr($2, 1, 8); $1 = ""; $2 = ""; sub(/^ +/, ""); sub(/:0x[0-9a-f-]+/, "")
                       k = substr($0, 1, 120); n[k]++; last[k] = t; ord[k] = NR}
                      END {for (k in n) print ord[k] "\t" last[k] " x" n[k] " " k}' | sort -n | tail -n 3 | cut -f2-)
        [ -n "$phases" ] && work=1
    fi
    ;;
clickhouse/*)
    engine=clickhouse
    ;;
esac
echo "requests: finished=$finished rows_processed=$rows (in the last $since s)"
if [ -n "$phases" ]; then sed 's/^/log: /' <<< "$phases" | cut -c1-170; else echo "log: no line of a statement thread in vertica.log in the last $since s"; fi

# ---- information only
cg=/sys/fs/cgroup/system.slice/vbitmap-engine.scope
cpu=$(awk '/^usage_usec/ {print $2}' "$cg/cpu.stat" 2>/dev/null); cpu=${cpu:-0}
io=$(awk '{for (i = 2; i <= NF; i++) if ($i ~ /^[rw]bytes=/) {split($i, a, "="); s += a[2]}} END {print s + 0}' "$cg/io.stat" 2>/dev/null); io=${io:-0}
dcpu=$(( (cpu - p_cpu) / 1000000 )); dio=$(( (io - p_io) / 1048576 ))
echo "engine (information only): cpu_s=$dcpu io_mb=$dio in the last $since s"

# ---- escalation probe: rows handled by the running statements (asked only without file evidence)
probe() {
    if [ "$engine" = vertica ]; then
        vsql -X -A -t -q -F ' ' 2>&1 <<'SQL' | tr '\n' ' '
SELECT COUNT(DISTINCT session_id), COALESCE(SUM_FLOAT(counter_value), 0)::INT
FROM v_monitor.execution_engine_profiles
WHERE counter_name IN ('rows produced', 'rows received')
  AND (session_id, transaction_id, statement_id) IN
      (SELECT session_id, transaction_id, statement_id FROM v_monitor.sessions
       WHERE current_statement <> '' AND session_id <> (SELECT session_id FROM v_monitor.current_session));
SQL
    else
        clickhouse-client --host ::1 --port 9000 -q "SELECT count(), sum(read_rows) + sum(written_rows) FROM system.processes WHERE query NOT LIKE '%system.processes%' FORMAT TSV" 2>&1 | tr '\t\n' '  '
    fi
}

# ---- verdict
changed=$p_changed; runchanged=$p_runchanged
[ "$runsig" != "$p_run" ] && runchanged=$now
if [ "$runsig" != "$p_run" ] || [ "$finished" -gt 0 ] || [ "$work" -gt 0 ]; then changed=$now; fi
state=running; reason=""
if [ $(( (now - changed) / 60 )) -ge "$STALL_MIN" ]; then
    t0=$(date +%s.%N); read -r st1 rows1 _ <<< "$(probe)"; ms=$(echo "($(date +%s.%N) - $t0) * 1000 / 1" | bc)
    sleep "$PROBE_GAP"
    read -r st2 rows2 _ <<< "$(probe)"
    echo "$(date -u '+%F %T')Z run=$run probes=2 gap_s=$PROBE_GAP first_probe_ms=$ms statements=$st1/$st2 rows_handled=$rows1/$rows2" >> monitor.log
    echo "probe: statements_running=$st2 rows_handled=$rows1 -> $rows2 in $PROBE_GAP s (first probe $ms ms)"
    if [[ "$rows1" =~ ^[0-9]+$ ]] && [[ "$rows2" =~ ^[0-9]+$ ]] && [ "$rows2" -gt "$rows1" ]; then
        changed=$(date +%s)          # rows moved: a long statement at work
    else
        state=STALL; reason=frozen
        [ "$since" -ge 60 ] && [ "$dcpu" -lt 2 ] && [ "$dio" -lt 1 ] && echo "engine_dead=yes"
    fi
    sleep 1                          # the probe's own session lines must not count as work next time
    [ -n "$logfile" ] && log=$(stat -c %s "$logfile" 2>/dev/null || echo 0)
    [ -n "$dc" ] && off=$(stat -c %s "$dc")
fi
if [ "$state" = running ] && [ $(( (now - runchanged) / 60 )) -ge "$BLOCK_MIN" ]; then state=STALL; reason=block; fi
echo "$now|$changed|$runchanged|$runsig|$dc|$off|$log|$cpu|$io" > "$STATE"
echo "minutes_without_evidence: any=$(( (now - changed) / 60 )) run_files=$(( (now - runchanged) / 60 ))"
echo "state=$state${reason:+ reason=$reason}"

#!/usr/bin/env bash
# watch.sh HOST [REPORT_MIN] [STALL_MIN] : run on the machine you work at; HOST is the ssh address of the
# benchmark machine. Runs status.sh there every 3 minutes (it reads log files; it asks the engine for row
# counts only when no log shows progress for STALL_MIN minutes). Ends, so that whoever started it looks:
#   - at once when status says STALL (no evidence of progress for STALL_MIN minutes, default 6)
#   - on a new run, on idle/done, on an unreachable workstation (3 times)
#   - after REPORT_MIN minutes (default 15) for a routine progress line while all is healthy
host=$1; report=${2:-15}; stall=${3:-6}
first=""; fails=0; t0=$(date +%s)
while :; do
    out=$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" "STALL_MIN=$stall bash ~/bitmap_record/status.sh" 2>&1)
    if [ $? -ne 0 ]; then fails=$((fails+1)); echo "ssh failed ($fails): $out" | head -3; [ $fails -ge 3 ] && { echo "WATCH_EXIT unreachable"; exit 2; }; sleep 60; continue; fi
    fails=0
    state=$(echo "$out" | grep -oE '^state=.*' | tail -n 1)
    run=$(echo "$out" | grep -oE 'run=[^ ]+' | head -n 1)
    echo "$out" | grep -E '^(time=|run:|requests:|log:|probe:|minutes_|engine_dead)' | cut -c1-200; echo "$state"
    [ -z "$first" ] && first=$run
    case "$state" in state=running) ;; *) echo "WATCH_EXIT $state"; echo "$out" | cut -c1-300; exit 0;; esac
    [ "$run" != "$first" ] && { echo "WATCH_EXIT new run: $run (was $first)"; exit 0; }
    [ $(( ($(date +%s) - t0) / 60 )) -ge "$report" ] && { echo "WATCH_EXIT routine report"; echo "$out" | cut -c1-300; exit 0; }
    sleep 175
done

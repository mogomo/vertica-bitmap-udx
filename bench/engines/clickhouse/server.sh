#!/usr/bin/env bash
# The benchmark's own ClickHouse server instance (not the packaged service, which stays disabled).
#
#   bench/engines/clickhouse/server.sh start|stop|up|pids
#
# start  renders config.xml and users.xml into $CH_HOME/config (default /data/xbench/clickhouse),
#        starts `clickhouse server --daemon` as the calling user and waits until /ping answers.
#        Started inside a systemd scope (bench/limits.sh), the daemon and its watchdog stay in it.
# stop   stops the instance and waits until no process is left.
# up     exit status 0 if the instance answers /ping.
# pids   the server processes (watchdog and server).
# Files of bench/limits.sh: $CH_HOME/config/config.d/limits.xml and users.d/limits.xml.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CH_HOME="${CH_HOME:-/data/xbench/clickhouse}"
CONF="$CH_HOME/config/config.xml"
PIDFILE="$CH_HOME/run/clickhouse.pid"
URL="http://[::1]:8123"

up()   { [ "$(curl -s --max-time 2 "$URL/ping" 2>/dev/null)" = "Ok." ]; }
pids() { pgrep -f -- "--config-file=$CONF" || true; }

case "${1:-}" in
start)
    if up; then echo "clickhouse: already up"; exit 0; fi
    mkdir -p "$CH_HOME"/{config/config.d,config/users.d,data,tmp,user_files,log,run}
    sed "s|@CH_HOME@|$CH_HOME|g" "$HERE/config.xml" > "$CONF"
    cp "$HERE/users.xml" "$CH_HOME/config/users.xml"
    clickhouse server --config-file="$CONF" --pid-file="$PIDFILE" --daemon
    for _ in $(seq 1 120); do
        if up; then echo "clickhouse: started ($(curl -s "$URL/?query=SELECT%20version()"))"; exit 0; fi
        sleep 1
    done
    echo "clickhouse: not answering after 120 s; see $CH_HOME/log/error.log" >&2; exit 1 ;;
stop)
    p=$(pids)
    [ -n "$p" ] || { echo "clickhouse: stopped"; exit 0; }
    # shellcheck disable=SC2086
    kill $p 2>/dev/null || true
    for _ in $(seq 1 120); do
        [ -z "$(pids)" ] && { echo "clickhouse: stopped"; exit 0; }
        sleep 1
    done
    echo "clickhouse: processes still running: $(pids | tr '\n' ' ')" >&2; exit 1 ;;
up)   up ;;
pids) pids ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac

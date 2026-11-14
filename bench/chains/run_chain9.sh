#!/usr/bin/env bash
# Chain 9: refresh reruns after the fix of touched-only validation (header fingerprint), tenant 10.
set -u
until grep -q ALL_DONE ~/bitmap_record/last_run8.log; do sleep 60; done
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
R="bench/record.sh --area=vertica --milestone=M5b"
bench/limits.sh status --check | tail -1
refresh() {   # NAME OPTIONS...
    local name=$1; shift
    $R --run=refresh-$name-t10 --purpose="refresh after the touched-validation fix (length + CRC header instead of whole payloads): $*" --scale="default (tenant 10)" --path="bench/refresh.sh" -- bench/refresh.sh --tenant=10 "$@"
}
refresh 1pct-random-delta-fp --fraction=0.01 --spread=random --report=delta
refresh 1pct-recent-mixed-fp --fraction=0.01 --spread=recent --report=mixed
refresh 1pct-random-mixed-fp --fraction=0.01 --spread=random --report=mixed
echo ALL_DONE

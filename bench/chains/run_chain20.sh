#!/usr/bin/env bash
# Chain 20: does the payload encoding change what a query costs?
# sql/schema.sql stores payloads with ZSTD_FAST_COMP since the aggregate builder (written 2.5 times
# faster than the default encoding). The published query numbers were measured on storage written
# with the default encoding. This chain measures the same queries on
#   orig   bitmap_demo.bitmap_index / daily_bitmap as they are (default encoding, the containers the
#          benchmark left)
#   auto   a copy with the default encoding   (bench/encoding_copy.sh: one INSERT, both projections)
#   zstd   a copy with ZSTD_FAST_COMP         (same script, same rows, same storage layout)
# so that auto against zstd shows the encoding alone and orig against auto the storage layout.
#  - 10 M, unfenced, 1 and 32 clients: the headline queries, the Q8 list as rows (INT and text) and
#    the Q8 audience joined to the profile rows (semi-join and row filter); two rounds, the second
#    in reverse order (the spread between rounds is the measure of what a difference means)
#  - 10 M, fenced: the headline queries on both copies
#  - 100 M, unfenced, 1 client: the six questions on both copies
# The copies stay until bench/encoding_copy.sh drop.
# A first attempt of this chain (runs enc-*) ran without the limits: its guard did not start them.
# bench/record.sh marked every run of it invalid; this is the chain as it ran with the limits.
set -u
cd ~/vertica-bitmap-udx
export PATH=/opt/vertica/bin:$PATH VSQL_DATABASE=VDB
RV="bench/record.sh --area=vertica --milestone=M5e"
REC=~/bitmap_record
XROWS=$(ls -d $REC/vertica/*_ids-rows-fenced-t10 | sort | head -1)/driver/check.csv
XUSE=$(ls -d $REC/vertica/*_ids-use-fenced-t10 | sort | head -1)/driver/check.csv
VCHECK=$(ls -d $REC/vertica/*_check-headline-t10 | sort | tail -1)/driver/check.csv
T20CHECK=$(ls -d $REC/vertica/*_latency-bitmap-c1c32-t20b | sort | tail -1)/driver/check.csv
D="python3 bench/driver.py"
HEAD=q1.count.Bplus,q1.ids.Bplus,q2.daily.B,q3.Bplus,q4.Bplus,q7.Bj,q7.Bplus,q8.Bplus
vrun() {   # NAME PURPOSE PATH WORKLOAD TENANT CLIENTS ONLY [driver options]
    local name=$1 purpose=$2 path=$3 wl=$4 tenant=$5 clients=$6 only=$7; shift 7
    $RV --run="$name" --purpose="$purpose" --scale="tenant $tenant" --path="$path" -- bash -c "$D run --client socket --workload bench/workloads/$wl --var tenant=$tenant --out \$BENCH_RUN_DIR/driver --clients $clients --iterations 15 --warmup 1 --statement-cap 300 --only $only $*"
}
tables() {   # orig|auto|zstd -> driver options naming the tables
    case $1 in
        orig) echo "" ;;
        auto) echo "--var index=bitmap_enc.index_auto --var daily=bitmap_enc.daily_auto" ;;
        zstd) echo "--var index=bitmap_enc.index_zstd --var daily=bitmap_enc.daily_zstd" ;;
    esac
}
what() { case $1 in orig) echo "the benchmark tables as they are (default encoding)" ;; auto) echo "the copy with the default encoding" ;; zstd) echo "the copy with ZSTD_FAST_COMP" ;; esac; }
round() {   # ROUND MODE TABLE...: headline, rows and row filter at 10 M
    local r=$1 m=$2 t; shift 2
    for t in "$@"; do
        vrun encoding-headline-$t-$m-r$r-t10 "payload encoding check, round $r, $m: headline queries on $(what $t)" "B, B+" vertica.sql 10 1,32 $HEAD $(tables $t) --expect $VCHECK --skip-oracles
        [ "$m" = unfenced ] || continue
        vrun encoding-rows-$t-$m-r$r-t10 "payload encoding check, round $r, $m: the Q8 ID list as INT rows and as text rows on $(what $t)" "B+ rows, B+ rowtext" vertica_ids.sql 10 1,32 q8.Bplus,q8.rowtext.Bplus $(tables $t | sed 's/ --var daily=[^ ]*//') --expect $XROWS --skip-oracles
        vrun encoding-join-$t-$m-r$r-t10 "payload encoding check, round $r, $m: the Q8 audience joined to the profile rows, semi-join with the ID list and row filter (bm_pin + bm_member) in one run as in chain 19, sets read from $(what $t)" "B+ join, B+ pin" vertica_ids.sql 10 1,32 q8.join.Bplus,q8.join.Bpin $(tables $t | sed 's/ --var daily=[^ ]*//') --expect $XUSE --skip-oracles
    done
}

limits_ok() { bench/limits.sh status --check > /dev/null 2>&1; }
limits_ok || bench/limits.sh start | tail -2
limits_ok || { echo "Vertica limits not in place: chain 20 stopped"; echo ALL_DONE; exit 1; }
bench/limits.sh status --check | tail -1
cp bench/chains/status.sh $REC/status.sh

$RV --run=encoding-copy-auto --purpose="copy of the index (both projections) and the daily sets of tenants 10 and 20 with the default payload encoding: one INSERT per table; time of the INSERTs, storage, content compared with the source" --scale="tenants 10, 20" --path="bench/encoding_copy.sh" -- bench/encoding_copy.sh create auto default
$RV --run=encoding-copy-zstd --purpose="the same copy with ZSTD_FAST_COMP payload encoding" --scale="tenants 10, 20" --path="bench/encoding_copy.sh" -- bench/encoding_copy.sh create zstd ZSTD_FAST_COMP
for c in auto zstd; do
    [ "$(grep -c "same_content=t" $(ls -d $REC/vertica/*_encoding-copy-$c | sort | tail -1)/console.log 2>/dev/null)" = 2 ] || { echo "copy $c differs from its source: chain 20 stopped"; echo ALL_DONE; exit 1; }
done

$RV --run=deploy-unfenced-17 --purpose="library deployed unfenced" --scale="none" --path="scripts/deploy.sh --fenced=no" -- scripts/deploy.sh --fenced=no
round 1 unfenced orig auto zstd
round 2 unfenced zstd auto orig
vrun encoding-headline-auto-unfenced-t20 "payload encoding check at 100 M people, 1 client, unfenced: the six questions on the copy with the default encoding" "B, B+" vertica.sql 20 1 $HEAD $(tables auto) --expect $T20CHECK --skip-oracles
vrun encoding-headline-zstd-unfenced-t20 "payload encoding check at 100 M people, 1 client, unfenced: the six questions on the copy with ZSTD_FAST_COMP" "B, B+" vertica.sql 20 1 $HEAD $(tables zstd) --expect $T20CHECK --skip-oracles
$RV --run=deploy-fenced-18 --purpose="library redeployed fenced (the default)" --scale="none" --path="scripts/deploy.sh --fenced=yes" -- scripts/deploy.sh --fenced=yes
round 1 fenced auto zstd
bench/limits.sh status --check | tail -1
echo ALL_DONE

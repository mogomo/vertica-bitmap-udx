#!/usr/bin/env bash
# Generates scale data for a tenant and source snapshot, inside Vertica (no files), and adds the demo
# predicate families for the tenant if it has none.
#
#   scripts/generate.sh --tenant=N --snapshot=N [--small | --default | --large] [options]
#
#   presets     --small     1,000,000 people, 10,000,000 events, 200,000 devices, 500,000 assets
#               --default  10,000,000 people, 100,000,000 events, 2,000,000 devices, 5,000,000 assets
#               --large   100,000,000 people, 1,000,000,000 events, 20,000,000 devices, 50,000,000 assets
#                         (20 topics each: 2,000,000,000 interests; plan D3 addition)
#               without a preset only people are generated (1,000,000 unless --users is given)
#   people      --users=N --topics=500 --topics-per-user=20 --topic-skew=0 (0 uniform; S > 0
#               skewed, 1.5 is the benchmark's setting: top topic 28%, tail 2.7%)
#               --id-order=signup|random|clustered
#               --id-space=dense|wide (wide: every chunk above 0 lies above 2^32)
#   events      --events=N --days=30 --start=2026-10-02 --user-skew=2 (needs the people)
#   devices     --devices=N --device-watermark='2026-11-01 12:00:00'
#   assets      --assets=N --refresh-start=2026-09-01
#   --seed=42   same seed and options give the same rows on any database
#   --replace   delete the tenant's generated rows of that snapshot first (events: all of the
#               tenant's events); otherwise existing rows are an error
#
# Distributions: the header of each sql/generate_*.sql. The last line of output is one summary line
# "generated: key=value ..." for the benchmark record. Connection: the VSQL_* environment variables.
set -euo pipefail

cd "$(dirname "$0")/.."

TENANT=""; SNAPSHOT=""; USERS=""; TOPICS=500; TPU=20; TSKEW=0; ORDER=signup; SPACE=dense
EVENTS=0; DAYS=30; START=2026-10-02; USKEW=2; DEVICES=0; DWM='2026-11-01 12:00:00'
ASSETS=0; RSTART=2026-09-01; SEED=42; REPLACE=no; PRESET=""
for arg in "$@"; do
    case "$arg" in
        --tenant=*)           TENANT="${arg#*=}" ;;
        --snapshot=*)         SNAPSHOT="${arg#*=}" ;;
        --small)              PRESET=small ;;
        --default)            PRESET=default ;;
        --large)              PRESET=large ;;
        --users=*)            USERS="${arg#*=}" ;;
        --topics=*)           TOPICS="${arg#*=}" ;;
        --topics-per-user=*)  TPU="${arg#*=}" ;;
        --topic-skew=*)       TSKEW="${arg#*=}" ;;
        --id-order=*)         ORDER="${arg#*=}" ;;
        --id-space=*)         SPACE="${arg#*=}" ;;
        --events=*)           EVENTS="${arg#*=}" ;;
        --days=*)             DAYS="${arg#*=}" ;;
        --start=*)            START="${arg#*=}" ;;
        --user-skew=*)        USKEW="${arg#*=}" ;;
        --devices=*)          DEVICES="${arg#*=}" ;;
        --device-watermark=*) DWM="${arg#*=}" ;;
        --assets=*)           ASSETS="${arg#*=}" ;;
        --refresh-start=*)    RSTART="${arg#*=}" ;;
        --seed=*)             SEED="${arg#*=}" ;;
        --replace)            REPLACE=yes ;;
        -h|--help)            sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "generate.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
# A preset sets the sizes that were not given explicitly.
case "$PRESET" in
    small)   USERS=${USERS:-1000000}
             [ "$EVENTS" != 0 ] || EVENTS=10000000;  [ "$DEVICES" != 0 ] || DEVICES=200000;  [ "$ASSETS" != 0 ] || ASSETS=500000 ;;
    default) USERS=${USERS:-10000000}
             [ "$EVENTS" != 0 ] || EVENTS=100000000; [ "$DEVICES" != 0 ] || DEVICES=2000000; [ "$ASSETS" != 0 ] || ASSETS=5000000 ;;
    large)   USERS=${USERS:-100000000}
             [ "$EVENTS" != 0 ] || EVENTS=1000000000; [ "$DEVICES" != 0 ] || DEVICES=20000000; [ "$ASSETS" != 0 ] || ASSETS=50000000 ;;
    *)       USERS=${USERS:-1000000} ;;
esac

bad() { echo "generate.sh: $*" >&2; exit 2; }
for v in "$TENANT" "$SNAPSHOT" "$USERS" "$TOPICS" "$TPU" "$EVENTS" "$DAYS" "$DEVICES" "$ASSETS" "$SEED"; do
    [[ "$v" =~ ^[0-9]+$ ]] || bad "--tenant, --snapshot, sizes and --seed must be nonnegative integers"
done
for v in "$TSKEW" "$USKEW"; do [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || bad "--topic-skew and --user-skew must be numbers"; done
for v in "$START" "$RSTART"; do [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || bad "--start and --refresh-start must be YYYY-MM-DD"; done
[[ "$DWM" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || bad "--device-watermark must be 'YYYY-MM-DD hh:mm:ss'"
[ "$TOPICS" -ge 1 ] && [ "$TOPICS" -le 1009 ] || bad "--topics must be 1 to 1009"
[ "$TPU" -ge 1 ] && [ "$TPU" -le "$TOPICS" ] || bad "--topics-per-user must be 1 to --topics"
[ "$USERS" -ge 1 ] || bad "--users must be positive"
[ "$DAYS" -ge 1 ] || bad "--days must be positive"
[ "$USKEW" != 0 ] && [ "$USKEW" != 0.0 ] || bad "--user-skew must be positive (1 is uniform)"
case "$ORDER" in
    signup)    expr="n" ;;
    random)    expr="(n * 2654435761 + 12345) % $USERS" ;;
    clustered) expr="(ROW_NUMBER() OVER (ORDER BY c, n) - 1)" ;;
    *) bad "--id-order must be signup, random or clustered" ;;
esac
case "$SPACE" in
    dense) ;;
    wide)  expr="(($expr) // 65536) * 1099511627776 + ($expr) % 65536" ;;
    *) bad "--id-space must be dense or wide" ;;
esac
blocks() { echo $(( ($1 + 999999) / 1000000 )); }

VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { "${VSQL[@]}" -c "$1"; }
where="tenant_id = $TENANT AND snapshot_id = $SNAPSHOT"
gen_exists=$(q "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'gen_person'")

# existing rows: refuse, or delete with --replace
existing=$(q "SELECT (SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE $where)
                   + (SELECT COUNT(*) FROM bitmap_demo.device_state WHERE $where)
                   + (SELECT COUNT(*) FROM bitmap_demo.asset_state WHERE $where)
                   + CASE WHEN $EVENTS > 0 THEN (SELECT COUNT(*) FROM bitmap_demo.event_log WHERE tenant_id = $TENANT) ELSE 0 END")
if [ "$existing" != 0 ]; then
    [ "$REPLACE" = yes ] || { echo "generate.sh: tenant $TENANT snapshot $SNAPSHOT already has $existing generated rows (use --replace)" >&2; exit 1; }
    del="DELETE FROM bitmap_demo.user_interest WHERE $where; DELETE FROM bitmap_demo.user_profile WHERE $where;
         DELETE FROM bitmap_demo.device_state WHERE $where; DELETE FROM bitmap_demo.asset_source WHERE $where;
         DELETE FROM bitmap_demo.asset_state WHERE $where;"
    [ "$gen_exists" = 0 ] || del+=" DELETE FROM bitmap_demo.gen_person WHERE $where;"
    [ "$EVENTS" = 0 ] || del+=" DELETE FROM bitmap_demo.event_log WHERE tenant_id = $TENANT;"
    q "$del COMMIT;" > /dev/null
    q "SELECT PURGE_TABLE('bitmap_demo.user_interest'), PURGE_TABLE('bitmap_demo.user_profile');" > /dev/null
elif [ "$gen_exists" = 1 ]; then
    q "DELETE FROM bitmap_demo.gen_person WHERE $where; COMMIT;" > /dev/null
fi
# (row number n, entity ID) of every generated person: the stated ID mapping (sql/generate_people.sql)
[ "$gen_exists" = 1 ] || q "CREATE TABLE bitmap_demo.gen_person (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, n INT NOT NULL, entity_id INT NOT NULL)
    ORDER BY tenant_id, snapshot_id, n SEGMENTED BY HASH(n) ALL NODES;" > /dev/null

summary="generated: tenant=$TENANT snapshot=$SNAPSHOT seed=$SEED id_order=$ORDER id_space=$SPACE"
total0=$(date +%s.%N)
step() {   # step NAME FILE vsql-variables...: run one generator file, print and record its time
    local name="$1" file="$2" t0 t; shift 2
    t0=$(date +%s.%N)
    "${VSQL[@]}" -v tenant="$TENANT" -v snapshot="$SNAPSHOT" -v seed="$SEED" "$@" -f "$file" > /dev/null
    t=$(printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)")
    echo "  $name: $t s"
    summary+=" ${name}_s=$t"
}

echo "generate tenant $TENANT snapshot $SNAPSHOT (seed $SEED, IDs $ORDER/$SPACE)"
step people sql/generate_people.sql -v users="$USERS" -v entity_expr="$expr"
if [ "$TSKEW" = 0 ] || [ "$TSKEW" = 0.0 ]; then
    step interests sql/generate_interests_uniform.sql -v topics="$TOPICS" -v topics_per_user="$TPU"
else
    step interests sql/generate_interests_skewed.sql -v topics="$TOPICS" -v topics_per_user="$TPU" -v topic_skew="$TSKEW"
fi
[ "$EVENTS" = 0 ] || step events sql/generate_events.sql -v users="$USERS" -v events="$EVENTS" \
    -v blocks="$(blocks "$EVENTS")" -v days="$DAYS" -v start="'$START 00:00:00'" -v user_skew="$USKEW"
[ "$DEVICES" = 0 ] || step devices sql/generate_devices.sql -v devices="$DEVICES" \
    -v blocks="$(blocks "$DEVICES")" -v watermark="'$DWM'"
[ "$ASSETS" = 0 ] || step assets sql/generate_assets.sql -v assets="$ASSETS" \
    -v blocks="$(blocks "$ASSETS")" -v refresh_start="'$RSTART 00:00:00'"

if [ "$(q "SELECT COUNT(*) FROM bitmap_demo.bitmap_family WHERE tenant_id = $TENANT")" = 0 ]; then
    "${VSQL[@]}" -v tenant="$TENANT" -f sql/families.sql > /dev/null
fi

# checks: one entity per row number, IDs unique and nonnegative
chk=$(q "SELECT COUNT(*) || '|' || COUNT(DISTINCT entity_id) || '|' || MIN(entity_id) || '|' || MAX(entity_id)
         FROM bitmap_demo.gen_person WHERE $where")
IFS='|' read -r cnt dist mn mx <<< "$chk"
[ "$cnt" = "$USERS" ] && [ "$dist" = "$USERS" ] && [ "$mn" -ge 0 ] \
    || { echo "generate.sh: ID mapping check failed: $cnt rows, $dist distinct IDs, min $mn (expected $USERS, $USERS, >= 0)" >&2; exit 1; }

counts=$(q "SELECT (SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE $where) || ' ' ||
                   (SELECT COUNT(*) FROM bitmap_demo.user_interest WHERE $where) || ' ' ||
                   (SELECT COUNT(*) FROM bitmap_demo.event_log WHERE tenant_id = $TENANT) || ' ' ||
                   (SELECT COUNT(*) FROM bitmap_demo.device_state WHERE $where) || ' ' ||
                   (SELECT COUNT(*) FROM bitmap_demo.asset_state WHERE $where) || ' ' ||
                   (SELECT COUNT(*) FROM bitmap_demo.asset_source WHERE $where)")
read -r np ni ne nd na ns <<< "$counts"
total=$(printf '%.1f' "$(echo "$(date +%s.%N) - $total0" | bc)")
echo "  rows: $np people, $ni interests, $ne events, $nd devices, $na assets, $ns asset sources; IDs $mn to $mx"
echo "$summary people=$np interests=$ni events=$ne devices=$nd assets=$na asset_sources=$ns topics=$TOPICS topics_per_user=$TPU topic_skew=$TSKEW days=$DAYS user_skew=$USKEW max_id=$mx total_s=$total"

#!/usr/bin/env bash
# The scale generator (scripts/generate.sh): deterministic; the three ID orders and the wide ID
# space give the same people, interests and events, only under other entity IDs; clustered IDs keep
# a country together; wide IDs keep the chunks and lie above 2^32; the generated device, asset and
# person data build, validate (ID by ID against native SQL) and answer Q4 like native SQL.
#
#   tests/sql/test_generate.sh [--users=300000]
#
# Uses tenants 5, 6 and 7 (test data only; removed first). Not part of run_all.sh (about 2 minutes).
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh

USERS=300000
for arg in "$@"; do
    case "$arg" in
        --users=*) USERS="${arg#*=}" ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "test_generate.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
SIZES=(--users="$USERS" --events=1000000 --devices=20000 --assets=20000 --topic-skew=1.5)
WM_PERSON='2026-11-01 00:00:00'; WM_DEVICE='2026-11-01 12:00:00'; WM_ASSET='2026-11-01 00:00:00'

if [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'bitmap_reader';")" != 1 ]; then
    tests/sql/test_fixture.sh > /dev/null || exit 1
fi
clear_tenant() {
    local t=$1 d="" tab
    for tab in bitmap_index bitmap_predicate daily_bitmap bitmap_membership bitmap_change bitmap_snapshot \
               user_interest user_profile event_log device_state asset_source asset_state bitmap_family; do
        d+="DELETE FROM bitmap_demo.$tab WHERE tenant_id = $t; "
    done
    [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'gen_person';")" = 0 ] \
        || d+="DELETE FROM bitmap_demo.gen_person WHERE tenant_id = $t; "
    run_sql "$d COMMIT;" > /dev/null
}
for t in 5 6 7; do clear_tenant $t; done

# checksum T: rows and hash sums of every generated table of tenant T (tenant column left out)
checksum() {
    run_sql "SELECT (SELECT COUNT(*) || ':' || SUM(HASH(entity_id, country, age, consent, suspended) % 1000003) FROM bitmap_demo.user_profile WHERE tenant_id = $1)
       || ' ' || (SELECT COUNT(*) || ':' || SUM(HASH(entity_id, topic) % 1000003) FROM bitmap_demo.user_interest WHERE tenant_id = $1)
       || ' ' || (SELECT COUNT(*) || ':' || SUM(HASH(event_id, user_id, event_ts, channel) % 1000003) FROM bitmap_demo.event_log WHERE tenant_id = $1)
       || ' ' || (SELECT COUNT(*) || ':' || SUM(HASH(device_id, online, zone, temp_tenths, changes_10m, observed_at) % 1000003) FROM bitmap_demo.device_state WHERE tenant_id = $1)
       || ' ' || (SELECT COUNT(*) || ':' || SUM(HASH(asset_id, contains_pii, deleted, refreshed_at) % 1000003) FROM bitmap_demo.asset_state WHERE tenant_id = $1)
       || ' ' || (SELECT COUNT(*) || ':' || SUM(HASH(asset_id, source) % 1000003) FROM bitmap_demo.asset_source WHERE tenant_id = $1);"
}
gen() { scripts/generate.sh --tenant="$1" --snapshot=1 "${SIZES[@]}" "${@:2}" > /dev/null; }

echo "== generate tenants 5 (signup, dense), 6 (random, dense), 7 (clustered, wide): $USERS people"
gen 5 || exit 1
c1=$(checksum 5)
gen 5 --replace || exit 1
c2=$(checksum 5)
if [ "$c1" = "$c2" ] && [ -n "$c1" ]; then pass "same seed and options give the same rows"; else fail "same seed and options give the same rows" "$c1" "$c2"; fi
expect_cmd "existing rows without --replace are refused" fail "already has" scripts/generate.sh --tenant=5 --snapshot=1 --users=10
gen 6 --id-order=random || exit 1
gen 7 --id-order=clustered --id-space=wide || exit 1

# The same person n in two tenants: identical attributes, interests and events.
for t in 6 7; do
    expect_eq "tenant $t: every person n has the attributes of tenant 5" "$USERS 0" "
        SELECT COUNT(*) || ' ' || SUM(CASE WHEN pa.country <=> pb.country AND pa.age <=> pb.age AND pa.consent <=> pb.consent
                                            AND pa.suspended <=> pb.suspended THEN 0 ELSE 1 END)
        FROM bitmap_demo.gen_person a JOIN bitmap_demo.user_profile pa ON pa.tenant_id = 5 AND pa.entity_id = a.entity_id
        JOIN bitmap_demo.gen_person b ON b.tenant_id = $t AND b.n = a.n
        JOIN bitmap_demo.user_profile pb ON pb.tenant_id = $t AND pb.entity_id = b.entity_id
        WHERE a.tenant_id = 5;"
    i5="SELECT g.n, i.topic FROM bitmap_demo.user_interest i JOIN bitmap_demo.gen_person g ON g.tenant_id = 5 AND g.entity_id = i.entity_id WHERE i.tenant_id = 5"
    it="SELECT g.n, i.topic FROM bitmap_demo.user_interest i JOIN bitmap_demo.gen_person g ON g.tenant_id = $t AND g.entity_id = i.entity_id WHERE i.tenant_id = $t"
    out="$(run_sql "$(set_diff_sql "$i5" "$it")") $(run_sql "$(set_diff_sql "$it" "$i5")") $(run_sql "SELECT CASE WHEN COUNT(*) > 0 THEN 'nonempty' ELSE 'EMPTY' END FROM ($it) x;")"
    if [ "$out" = "0 0 nonempty" ]; then pass "tenant $t: same interests per person n"; else fail "tenant $t: same interests per person n" "0 0 nonempty" "$out"; fi
    e5="SELECT e.event_id, g.n, e.event_ts, e.channel FROM bitmap_demo.event_log e JOIN bitmap_demo.gen_person g ON g.tenant_id = 5 AND g.entity_id = e.user_id WHERE e.tenant_id = 5"
    et="SELECT e.event_id, g.n, e.event_ts, e.channel FROM bitmap_demo.event_log e JOIN bitmap_demo.gen_person g ON g.tenant_id = $t AND g.entity_id = e.user_id WHERE e.tenant_id = $t"
    out="$(run_sql "$(set_diff_sql "$e5" "$et")") $(run_sql "$(set_diff_sql "$et" "$e5")") $(run_sql "SELECT COUNT(*) FROM ($et) x;")"
    if [ "$out" = "0 0 1000000" ]; then pass "tenant $t: same 1,000,000 events per person n"; else fail "tenant $t: same 1,000,000 events per person n" "0 0 1000000" "$out"; fi
done
expect_eq "devices and assets do not depend on the ID order" "0 0 0 0" "
    SELECT (SELECT COUNT(*) FROM (SELECT device_id, online, zone, temp_tenths, changes_10m, observed_at FROM bitmap_demo.device_state WHERE tenant_id = 5
                                  EXCEPT SELECT device_id, online, zone, temp_tenths, changes_10m, observed_at FROM bitmap_demo.device_state WHERE tenant_id = 7) x)
     || ' ' || (SELECT COUNT(*) FROM (SELECT device_id, online, zone, temp_tenths, changes_10m, observed_at FROM bitmap_demo.device_state WHERE tenant_id = 7
                                  EXCEPT SELECT device_id, online, zone, temp_tenths, changes_10m, observed_at FROM bitmap_demo.device_state WHERE tenant_id = 5) x)
     || ' ' || (SELECT COUNT(*) FROM (SELECT asset_id, source FROM bitmap_demo.asset_source WHERE tenant_id = 5
                                  EXCEPT SELECT asset_id, source FROM bitmap_demo.asset_source WHERE tenant_id = 7) x)
     || ' ' || (SELECT COUNT(*) FROM (SELECT asset_id, source FROM bitmap_demo.asset_source WHERE tenant_id = 7
                                  EXCEPT SELECT asset_id, source FROM bitmap_demo.asset_source WHERE tenant_id = 5) x);"

# ID orders and ID space
expect_eq "random order: a permutation of 0 .. users-1, not the identity" "0 $((USERS - 1)) $USERS yes" "
    SELECT MIN(entity_id) || ' ' || MAX(entity_id) || ' ' || COUNT(DISTINCT entity_id) || ' '
           || CASE WHEN SUM(CASE WHEN entity_id = n THEN 1 ELSE 0 END) < COUNT(*) / 100 THEN 'yes' ELSE 'no' END
    FROM bitmap_demo.gen_person WHERE tenant_id = 6;"
expect_eq "clustered order: each country is one run of consecutive IDs" "yes" "
    SELECT CASE WHEN SUM(chg) = COUNT(DISTINCT country) - 1 THEN 'yes' ELSE 'no: ' || SUM(chg) || ' changes' END
    FROM (SELECT country, CASE WHEN LAG(country) OVER (ORDER BY entity_id) <> country THEN 1 ELSE 0 END AS chg
          FROM bitmap_demo.user_profile WHERE tenant_id = 7) x;"
chunks=$(( (USERS + 65535) / 65536 ))
expect_eq "wide space: same $chunks chunks, every ID of a chunk above 0 is at least 2^32" "$chunks $chunks 0" "
    SELECT (SELECT COUNT(DISTINCT entity_id >> 16) FROM bitmap_demo.user_profile WHERE tenant_id = 5) || ' ' ||
           (SELECT COUNT(DISTINCT entity_id >> 16) FROM bitmap_demo.user_profile WHERE tenant_id = 7) || ' ' ||
           (SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE tenant_id = 7 AND entity_id >= 65536 AND entity_id < 4294967296);"

# Distributions (tolerances far wider than the sampling error)
expect_eq "channels about 55 / 30 / 10 / 5 %" "app:30 email:10 store:5 web:55" "
    SELECT channel || ':' || ROUND(100.0 * COUNT(*) / 1000000)::INT FROM bitmap_demo.event_log WHERE tenant_id = 5 GROUP BY channel ORDER BY channel;"
expect_eq "30 days of events, 2026-10-02 to 2026-10-31" "30 2026-10-02 2026-10-31" "
    SELECT COUNT(DISTINCT event_ts::DATE) || ' ' || MIN(event_ts)::DATE || ' ' || MAX(event_ts)::DATE FROM bitmap_demo.event_log WHERE tenant_id = 5;"
expect_eq "about 5 % of devices expired at the watermark" "5" "
    SELECT ROUND(100.0 * SUM(CASE WHEN observed_at <= TIMESTAMPADD('minute', -30, '$WM_DEVICE'::TIMESTAMP) THEN 1 ELSE 0 END) / COUNT(*))::INT
    FROM bitmap_demo.device_state WHERE tenant_id = 5;"
expect_eq "skewed topics: sports most popular, every person 16 to 20 topics" "sports yes" "
    SELECT (SELECT topic FROM bitmap_demo.user_interest WHERE tenant_id = 5 GROUP BY topic ORDER BY COUNT(*) DESC LIMIT 1) || ' ' ||
           (SELECT CASE WHEN MIN(c) >= 16 AND MAX(c) = 20 THEN 'yes' ELSE 'no' END
            FROM (SELECT entity_id, COUNT(*) AS c FROM bitmap_demo.user_interest WHERE tenant_id = 5 GROUP BY entity_id) x);"

# The generated data through the lifecycle: build with deep validation (ID by ID), Q4 agreement.
echo "== build and validate (deep): tenant 7 person with daily sets (64-bit IDs), tenant 5 device and asset"
expect_cmd "tenant 7 person + daily sets (clustered, wide IDs): built and verified ID by ID" ok "verified" \
    scripts/snapshot.sh build --tenant=7 --domain=person --snapshot=1 --watermark="$WM_PERSON" --daily --deep
expect_cmd "tenant 5 device: built and verified ID by ID" ok "verified" \
    scripts/snapshot.sh build --tenant=5 --domain=device --snapshot=1 --watermark="$WM_DEVICE" --deep
expect_cmd "tenant 5 asset: built and verified ID by ID" ok "verified" \
    scripts/snapshot.sh build --tenant=5 --domain=asset --snapshot=1 --watermark="$WM_ASSET" --deep
expect_same_set "Q4 on generated devices: expression = native" q4/native q4/expr 5 1 "$WM_DEVICE"

for t in 5 6 7; do clear_tenant $t; done
finish_tests test_generate

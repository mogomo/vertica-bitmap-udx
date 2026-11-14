#!/usr/bin/env bash
# Snapshot lifecycle on the fixture (scripts/snapshot.sh, docs/LIFECYCLE.md): states and publish,
# a failed build that readers never see and its retry, validation of a tampered snapshot, ordered
# add / remove / re-add, removal of one event while another keeps the user in the daily set,
# expiry of device state, incremental builds equal to full builds byte for byte, touched-only
# validation (and the unreported source change it cannot see), idempotent
# replay, pinned and retired snapshots, purge, rollback, and tenant isolation through the reader
# views and the query role.
#
#   tests/sql/test_lifecycle.sh
#
# Drops and recreates schema bitmap_demo; creates and drops database user bitmap_demo_reader2.
# Needs the functions installed (make deploy) and build/bmexpr.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh

SNAP=scripts/snapshot.sh
READER=bitmap_demo_reader2
Q1='country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)'
Q4='online_true & zone_A & temp_ge_800 & changes_gt_3'

state()  { run_sql "SELECT state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $1 AND domain = '$2' AND snapshot_id = $3;"; }
active() { run_sql "SELECT snapshot_id FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $1 AND domain = '$2' AND state = 'active';"; }
# same_payloads A B: index and daily rows of person snapshots A and B of tenant 1, compared as
# (key, payload) sets in both directions, then "nonempty" if A has index and daily rows (SQL).
same_payloads() {
    local i="SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id"
    local d="SELECT day, channel, chunk_id, payload FROM bitmap_demo.daily_bitmap WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id"
    echo "SELECT (SELECT COUNT(*) FROM ($i = $1 EXCEPT $i = $2) a) || ' ' || (SELECT COUNT(*) FROM ($i = $2 EXCEPT $i = $1) b)
                || ' ' || (SELECT COUNT(*) FROM ($d = $1 EXCEPT $d = $2) c) || ' ' || (SELECT COUNT(*) FROM ($d = $2 EXCEPT $d = $1) e)
                || ' ' || (SELECT CASE WHEN (SELECT COUNT(*) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = $1) > 0
                                        AND (SELECT COUNT(*) FROM bitmap_demo.daily_bitmap WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = $1) > 0
                                       THEN 'nonempty' ELSE 'EMPTY' END);"
}
# copy_source FROM TO: person source snapshot TO of tenant 1 = snapshot FROM.
copy_source() {
    run_sql "INSERT INTO bitmap_demo.user_profile SELECT tenant_id, $2, entity_id, country, age, consent, suspended
               FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id = $1;
             INSERT INTO bitmap_demo.user_interest SELECT tenant_id, $2, entity_id, topic
               FROM bitmap_demo.user_interest WHERE tenant_id = 1 AND snapshot_id = $1;
             COMMIT;" > /dev/null
}

echo "== setup: fixture, snapshot 1 of every domain published"
setup_fixture || exit 1
expect_eq "active snapshots" "1 1 1" "SELECT snapshot_id FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND state = 'active' ORDER BY domain;"
expect_cmd "bmq reads the active snapshot through the views" ok "^3$" scripts/bmq "$Q1"

echo "== a failed build is never visible; the retry rebuilds the same snapshot"
copy_source 1 2
run_sql "INSERT INTO bitmap_demo.user_profile SELECT 1, 2, -5, 'IL', 30, true, false; COMMIT;" > /dev/null
expect_cmd "build of snapshot 2 fails (negative entity ID in the source)" fail "build failed: .*local ID -1 is outside" \
  $SNAP build --tenant=1 --domain=person --snapshot=2 --watermark="$FIX_WM_PERSON" --daily
expect_eq  "failed snapshot stays building, with the reason" "building|t" \
  "SELECT state, note LIKE 'build failed%' FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = 2;"
expect_cmd "a building snapshot cannot be published" fail "is building: only a verified or retired snapshot can be published" \
  $SNAP publish --tenant=1 --domain=person --snapshot=2
expect_eq  "readers: still snapshot 1, no row of snapshot 2 in the views" "1|0|0" \
  "SELECT (SELECT snapshot_id FROM bitmap_demo.v_bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND state = 'active'),
          (SELECT COUNT(*) FROM bitmap_demo.v_bitmap_index WHERE tenant_id = 1 AND snapshot_id = 2),
          (SELECT COUNT(*) FROM bitmap_demo.v_daily_bitmap WHERE tenant_id = 1 AND snapshot_id = 2);"
expect_cmd "bmq answers from snapshot 1 meanwhile" ok "^3$" scripts/bmq "$Q1"
run_sql "DELETE FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id = 2 AND entity_id = -5; COMMIT;" > /dev/null
expect_cmd "retry: the same build now verifies" ok "snapshot 2 of tenant 1 domain person: verified" \
  $SNAP build --tenant=1 --domain=person --snapshot=2 --watermark="$FIX_WM_PERSON" --daily --deep
expect_eq  "same source, same payloads as snapshot 1 (index and daily, both directions)" "0 0 0 0 nonempty" "$(same_payloads 2 1)"
expect_cmd "a verified snapshot is never rebuilt" fail "is verified: a built snapshot is never changed" \
  $SNAP build --tenant=1 --domain=person --snapshot=2 --watermark="$FIX_WM_PERSON" --daily
expect_cmd "publish snapshot 2" ok "snapshot 2 of tenant 1 domain person: active" $SNAP publish --tenant=1 --domain=person --snapshot=2
expect_cmd "publishing it again changes nothing" ok "already active" $SNAP publish --tenant=1 --domain=person --snapshot=2
expect_eq  "snapshot 1 retired, 2 active" "retired active" "SELECT state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id IN (1, 2) ORDER BY snapshot_id;"
expect_cmd "retired snapshot 1 stays readable for pinned readers" ok "^3$" scripts/bmq --snapshot=1 "$Q1"

echo "== validation catches a wrong set and a damaged payload"
expect_cmd "build snapshot 3" ok "verified" $SNAP build --tenant=1 --domain=person --snapshot=3 --source-snapshot=2 --watermark="$FIX_WM_PERSON" --daily
hex=$(run_sql "SELECT TO_HEX(payload) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 3 AND predicate = 'topic_finance' AND chunk_id = 0;")
run_sql "UPDATE bitmap_demo.bitmap_index SET payload = HEX_TO_BINARY('0x$hex')
         WHERE tenant_id = 1 AND snapshot_id = 3 AND predicate = 'topic_sports' AND chunk_id = 0; COMMIT;" > /dev/null
expect_cmd "a valid payload holding the wrong set fails validation" fail "topic_sports chunk 0: native 4, index 2" \
  $SNAP validate --tenant=1 --domain=person --snapshot=3
expect_eq  "the snapshot is demoted to building" "building" "SELECT state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = 3;"
run_sql "UPDATE bitmap_demo.bitmap_index SET payload = SUBSTR(payload, 1, 19) || HEX_TO_BINARY('0xFF') || SUBSTR(payload, 21)
         WHERE tenant_id = 1 AND snapshot_id = 3 AND predicate = 'country_IL' AND chunk_id = 0; COMMIT;" > /dev/null
expect_cmd "a damaged payload fails validation (checksum)" fail "checksum mismatch" $SNAP validate --tenant=1 --domain=person --snapshot=3
expect_cmd "and cannot be published" fail "is building" $SNAP publish --tenant=1 --domain=person --snapshot=3
expect_cmd "discard the unpublished snapshot" ok "discarded" $SNAP discard --tenant=1 --domain=person --snapshot=3
expect_eq  "nothing of snapshot 3 is left" "0" \
  "SELECT (SELECT COUNT(*) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 3) + (SELECT COUNT(*) FROM bitmap_demo.daily_bitmap WHERE tenant_id = 1 AND snapshot_id = 3)
        + (SELECT COUNT(*) FROM bitmap_demo.bitmap_predicate WHERE tenant_id = 1 AND snapshot_id = 3) + (SELECT COUNT(*) FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND snapshot_id = 3);"
expect_cmd "an active snapshot cannot be discarded" fail "only an unpublished snapshot can be discarded" $SNAP discard --tenant=1 --domain=person --snapshot=2

echo "== ordered add, remove, re-add: batch 1 applied as (base ANDNOT removed) OR added, last change wins"
expect_cmd "a batch without changes is refused" fail "batch 1 has no changes" $SNAP apply --tenant=1 --domain=person --batch=1
# The source system changes interests (source snapshot 3) and reports the same changes in order.
copy_source 2 3
run_sql "INSERT INTO bitmap_demo.user_interest SELECT 1, 3, 2, 'chess' UNION ALL SELECT 1, 3, 65536, 'chess'
                                               UNION ALL SELECT 1, 3, 4294967296, 'finance';
         DELETE FROM bitmap_demo.user_interest WHERE tenant_id = 1 AND snapshot_id = 3 AND entity_id = 1 AND topic = 'sports';
         INSERT INTO bitmap_demo.bitmap_change (tenant_id, domain, batch_id, seq, op, predicate, entity_id)
                   SELECT 1, 'person', 1, 1, 'add',    'topic_chess',   2
         UNION ALL SELECT 1, 'person', 1, 2, 'add',    'topic_chess',   3
         UNION ALL SELECT 1, 'person', 1, 3, 'remove', 'topic_chess',   2
         UNION ALL SELECT 1, 'person', 1, 4, 'add',    'topic_chess',   2
         UNION ALL SELECT 1, 'person', 1, 5, 'remove', 'topic_chess',   3
         UNION ALL SELECT 1, 'person', 1, 6, 'add',    'topic_chess',   65536
         UNION ALL SELECT 1, 'person', 1, 7, 'remove', 'topic_sports',  1
         UNION ALL SELECT 1, 'person', 1, 8, 'add',    'topic_finance', 4294967296;
         COMMIT;" > /dev/null
expect_cmd "apply batch 1 onto active snapshot 2 (source snapshot 3)" ok "4 \(predicate, chunk\) sets changed by delta" \
  $SNAP apply --tenant=1 --domain=person --batch=1 --source-snapshot=3 --snapshot=4 --deep
expect_eq  "snapshot 4: base 2, batch 1, verified" "2|1|3|verified" \
  "SELECT base_snapshot_id, batch_id, source_snapshot_id, state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = 4;"
expect_cmd "re-added 2 is in topic_chess, added-then-removed 3 is not" ok "^2 65536 $" \
  bash -c "scripts/bmq --raw --snapshot=4 --mode=ids topic_chess | tr '\n' ' '"
expect_eq  "order matters: unordered union then removal gives 1, removal then union gives 3, ordered gives 2" "1|3|2" \
  "SELECT (SELECT COUNT(*) FROM (SELECT entity_id FROM bitmap_demo.bitmap_change WHERE batch_id = 1 AND predicate = 'topic_chess' AND op = 'add'
                                 EXCEPT SELECT entity_id FROM bitmap_demo.bitmap_change WHERE batch_id = 1 AND predicate = 'topic_chess' AND op = 'remove') a),
          (SELECT COUNT(DISTINCT entity_id) FROM bitmap_demo.bitmap_change WHERE batch_id = 1 AND predicate = 'topic_chess' AND op = 'add'),
          (SELECT SUM(vbitmap.bm_cardinality(payload)) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 4 AND predicate = 'topic_chess');"
expect_cmd "full build of the same source (snapshot 5)" ok "verified" \
  $SNAP build --tenant=1 --domain=person --snapshot=5 --source-snapshot=3 --batch=1 --watermark="$FIX_WM_PERSON" --daily
expect_eq  "incremental snapshot 4 = full snapshot 5, byte for byte" "0 0 0 0 nonempty" "$(same_payloads 4 5)"
$SNAP discard --tenant=1 --domain=person --snapshot=5 > /dev/null
expect_cmd "Q1 on snapshot 4: user 1 left sports" ok "^65536 4294967296 $" bash -c "scripts/bmq --raw --snapshot=4 --mode=ids '$Q1' | tr '\n' ' '"
expect_cmd "publish snapshot 4" ok "active" $SNAP publish --tenant=1 --domain=person --snapshot=4
expect_cmd "readers switch: Q1 = 2" ok "^2$" scripts/bmq "$Q1"
expect_cmd "replay of batch 1 does nothing" ok "batch 1 is already applied: active snapshot 4" $SNAP apply --tenant=1 --domain=person --batch=1 --source-snapshot=3
expect_eq  "no snapshot was added by the replay" "1 2 4" "SELECT snapshot_id FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' ORDER BY 1;"
expect_cmd "a batch out of order is refused" fail "batch 3 does not follow batch 1" $SNAP apply --tenant=1 --domain=person --batch=3
expect_cmd "a change naming no family is refused" fail "predicate hobby_chess matches 0 families" bash -c "
  printf '%s\n' \"INSERT INTO bitmap_demo.bitmap_change SELECT 1, 'person', 2, 1, 'add', 'hobby_chess', 2; COMMIT;\" | vsql -X -q > /dev/null
  $SNAP apply --tenant=1 --domain=person --batch=2 --snapshot=5"
expect_eq  "the failed apply left snapshot 5 building" "building" "SELECT state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = 5;"
run_sql "DELETE FROM bitmap_demo.bitmap_change WHERE batch_id = 2; COMMIT;" > /dev/null

echo "== event removal: another event keeps the user in the daily set (batch 2 touches users 1 and 65536)"
# Batch 2 is corrected (above) and applied again: the retry reuses the failed snapshot 5.
# User 1 had two web events on 2026-11-01 (1 and 2), user 65536 one (3). Events 1 and 3 are removed.
run_sql "DELETE FROM bitmap_demo.event_log WHERE tenant_id = 1 AND event_id IN (1, 3);
         INSERT INTO bitmap_demo.bitmap_change (tenant_id, domain, batch_id, seq, op, predicate, entity_id)
                   SELECT 1, 'person', 2, 1, 'touch', NULL, 1
         UNION ALL SELECT 1, 'person', 2, 2, 'touch', NULL, 65536;
         COMMIT;" > /dev/null
expect_cmd "retry of batch 2 reuses snapshot 5" ok "snapshot 5 of tenant 1 domain person: building from snapshot 4 \+ batch 2" \
  $SNAP apply --tenant=1 --domain=person --batch=2 --deep
expect_eq  "snapshot 5: chunks 0 and 1 rebuilt from the source, chunk 65536 copied; verified" "verified" \
  "SELECT state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = 5;"
expect_query "daily web users on snapshot 5: 2026-11-01 keeps user 1" q2/bitmap_daily 1 5 "2026-11-01|1 2026-11-02|2"
expect_query "native daily web users agree" q2/native_daily 1 5 "2026-11-01|1 2026-11-02|2"
expect_eq  "user 1 still in 2026-11-01 web; user 65536 left it (no payload in chunk 1)" "t|0" \
  "SELECT (SELECT vbitmap.bm_contains(payload, 1) FROM bitmap_demo.daily_bitmap WHERE tenant_id = 1 AND snapshot_id = 5
           AND day = '2026-11-01' AND channel = 'web' AND chunk_id = 0),
          (SELECT COUNT(*) FROM bitmap_demo.daily_bitmap WHERE tenant_id = 1 AND snapshot_id = 5 AND day = '2026-11-01' AND channel = 'web' AND chunk_id = 1);"
expect_eq  "untouched chunk 65536 copied unchanged" "0" \
  "SELECT COUNT(*) FROM (SELECT day, channel, payload FROM bitmap_demo.daily_bitmap WHERE tenant_id = 1 AND snapshot_id = 5 AND chunk_id = 65536
                         EXCEPT SELECT day, channel, payload FROM bitmap_demo.daily_bitmap WHERE tenant_id = 1 AND snapshot_id = 4 AND chunk_id = 65536) d;"
expect_cmd "full build at the same state (snapshot 6)" ok "verified" \
  $SNAP build --tenant=1 --domain=person --snapshot=6 --source-snapshot=3 --batch=2 --watermark="$FIX_WM_PERSON" --daily
expect_eq  "incremental snapshot 5 = full snapshot 6, byte for byte" "0 0 0 0 nonempty" "$(same_payloads 5 6)"
$SNAP discard --tenant=1 --domain=person --snapshot=6 > /dev/null
expect_cmd "publish snapshot 5" ok "active" $SNAP publish --tenant=1 --domain=person --snapshot=5
expect_eq  "readers: Q2 over both days through the views = 2" "2" \
  "SELECT SUM(vbitmap.bm_cardinality(payload)) FROM (
     SELECT vbitmap.bm_union(tenant_id, domain, chunk_id, payload) OVER (PARTITION BY tenant_id, domain, chunk_id)
     FROM bitmap_demo.v_daily_bitmap WHERE tenant_id = 1 AND domain = 'person' AND channel = 'web'
       AND snapshot_id = (SELECT snapshot_id FROM bitmap_demo.v_bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND state = 'active')) m;"

echo "== touched-only validation: changed parts against the source, every other row against the base"
# Source snapshot 4 = 3 with user 1 moved to DE (reported as a touch of chunk 0) and user 65536
# gaining cooking (reported as an add in chunk 1).
copy_source 3 4
run_sql "UPDATE bitmap_demo.user_profile SET country = 'DE' WHERE tenant_id = 1 AND snapshot_id = 4 AND entity_id = 1;
         INSERT INTO bitmap_demo.user_interest SELECT 1, 4, 65536, 'cooking';
         INSERT INTO bitmap_demo.bitmap_change (tenant_id, domain, batch_id, seq, op, predicate, entity_id)
                   SELECT 1, 'person', 3, 1, 'touch', NULL, 1
         UNION ALL SELECT 1, 'person', 3, 2, 'add', 'topic_cooking', 65536;
         COMMIT;" > /dev/null
expect_cmd "apply batch 3 with --validate=touched (snapshot 6)" ok "scope: touched only \(base snapshot 5, batch 3, rebuilt in full: none\)" \
  $SNAP apply --tenant=1 --domain=person --batch=3 --source-snapshot=4 --snapshot=6 --validate=touched
expect_eq  "snapshot 6 verified" "verified" "SELECT state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id = 6;"
expect_cmd "full build of the same state (snapshot 7)" ok "verified" \
  $SNAP build --tenant=1 --domain=person --snapshot=7 --source-snapshot=4 --batch=3 --watermark="$FIX_WM_PERSON" --daily
expect_eq  "snapshot 6 = full snapshot 7, byte for byte" "0 0 0 0 nonempty" "$(same_payloads 6 7)"
$SNAP discard --tenant=1 --domain=person --snapshot=7 > /dev/null
expect_cmd "the full validation of snapshot 6 agrees" ok "snapshot 6 of tenant 1 domain person: verified" \
  $SNAP validate --tenant=1 --domain=person --snapshot=6
# The documented limit: source snapshot 5 also drops chess of user 65536, which batch 4 does not
# report. Touched-only validation does not read that part of the source; the full one does.
copy_source 4 5
run_sql "DELETE FROM bitmap_demo.user_interest WHERE tenant_id = 1 AND snapshot_id = 5 AND entity_id = 65536 AND topic = 'chess';
         INSERT INTO bitmap_demo.user_interest SELECT 1, 5, 3, 'cooking';
         INSERT INTO bitmap_demo.bitmap_change (tenant_id, domain, batch_id, seq, op, predicate, entity_id)
           SELECT 1, 'person', 4, 1, 'add', 'topic_cooking', 3;
         COMMIT;" > /dev/null
expect_cmd "an unreported source change passes touched-only validation (documented limit)" ok "snapshot 7 of tenant 1 domain person: verified" \
  $SNAP apply --tenant=1 --domain=person --from=6 --batch=4 --source-snapshot=5 --snapshot=7 --validate=touched
expect_cmd "the full validation finds it" fail "topic_chess chunk 1: native 0, index 1" \
  $SNAP validate --tenant=1 --domain=person --snapshot=7
expect_cmd "--validate=touched is refused outside apply" fail "applies to apply only" \
  $SNAP validate --tenant=1 --domain=person --snapshot=6 --validate=touched
expect_cmd "chunk bits above 16 are refused before building (VARBINARY(16384) payload columns)" fail "chunk-bits must be 8 to 16" \
  $SNAP build --tenant=1 --domain=person --snapshot=8 --watermark='2026-11-03 00:00:00' --chunk-bits=18
for s2 in 7 6; do $SNAP discard --tenant=1 --domain=person --snapshot=$s2 > /dev/null; done
run_sql "DELETE FROM bitmap_demo.bitmap_change WHERE tenant_id = 1 AND batch_id IN (3, 4);
         DELETE FROM bitmap_demo.user_profile WHERE tenant_id = 1 AND snapshot_id IN (4, 5);
         DELETE FROM bitmap_demo.user_interest WHERE tenant_id = 1 AND snapshot_id IN (4, 5); COMMIT;" > /dev/null
expect_eq  "manifest of tenant 1 person unchanged by this section" "1|retired 2|retired 4|retired 5|active" \
  "SELECT snapshot_id, state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' ORDER BY 1;"

echo "== expiry: device state older than 30 minutes leaves every set when the watermark moves"
# Source snapshot 2 of the devices: only device 11 reports again, at 12:35, now at 85.0 C.
run_sql "INSERT INTO bitmap_demo.device_state
           SELECT tenant_id, 2, device_id, online, zone, temp_tenths, changes_10m, observed_at FROM bitmap_demo.device_state
           WHERE tenant_id = 1 AND snapshot_id = 1 AND device_id <> 11
           UNION ALL SELECT 1, 2, 11, true, 'A', 850, 5, '2026-11-01 12:35:00'::TIMESTAMP;
         COMMIT;" > /dev/null
expect_cmd "apply at watermark 12:40: every device family depends on it and is rebuilt" ok "rebuilt in full: changes,online,temperature,zone" \
  $SNAP apply --tenant=1 --domain=device --source-snapshot=2 --watermark='2026-11-01 12:40:00' --snapshot=2 --deep --publish
expect_cmd "Q4 at 12:40 = device 11 (device 10's reading from 12:00 expired)" ok "^11$" scripts/bmq --domain=device --mode=ids "$Q4"
expect_query "native Q4 at 12:40 agrees" q4/native 1 2 "11" '2026-11-01 12:40:00'
expect_eq  "without the age rule device 10 would still be reported" "10 11" \
  "SELECT device_id FROM bitmap_demo.device_state WHERE tenant_id = 1 AND snapshot_id = 2
     AND online IS TRUE AND zone = 'A' AND temp_tenths >= 800 AND changes_10m > 3 ORDER BY 1;"
expect_cmd "online_true holds only the fresh device" ok "^11$" scripts/bmq --domain=device --mode=ids online_true
expect_cmd "the old device snapshot still answers 10" ok "^10$" scripts/bmq --domain=device --snapshot=1 --mode=ids "$Q4"

echo "== rollback, retirement and purge"
expect_cmd "rollback: publish retired snapshot 4 again" ok "snapshot 4 of tenant 1 domain person: active" $SNAP publish --tenant=1 --domain=person --snapshot=4
expect_cmd "readers see snapshot 4 (2026-11-01 web daily set still has user 65536)" ok "^4 5$" bash -c \
  "printf '%s\n' \"SELECT (SELECT snapshot_id FROM bitmap_demo.v_bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND state = 'active') || ' ' ||
                       (SELECT snapshot_id FROM bitmap_demo.v_bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' AND state = 'retired' ORDER BY retired_at DESC LIMIT 1);\" | vsql -X -A -t -q"
expect_cmd "publish snapshot 5 again" ok "active" $SNAP publish --tenant=1 --domain=person --snapshot=5
expect_cmd "purge keeps the most recently retired snapshot (4)" ok "removed retired snapshots 1 2" $SNAP purge --tenant=1 --domain=person --keep=1
expect_eq  "manifest of tenant 1 person after purge" "4|retired 5|active" \
  "SELECT snapshot_id, state FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = 1 AND domain = 'person' ORDER BY 1;"
expect_eq  "no row of purged snapshots 1 and 2 is left" "0" \
  "SELECT (SELECT COUNT(*) FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id IN (1, 2))
        + (SELECT COUNT(*) FROM bitmap_demo.daily_bitmap WHERE tenant_id = 1 AND snapshot_id IN (1, 2))
        + (SELECT COUNT(*) FROM bitmap_demo.bitmap_predicate WHERE tenant_id = 1 AND domain = 'person' AND snapshot_id IN (1, 2));"
expect_cmd "a reader pinned to purged snapshot 1 gets an error, not a number" fail "no published snapshot 1" scripts/bmq --snapshot=1 "$Q1"
expect_cmd "purge again: nothing to do" ok "nothing to purge" $SNAP purge --tenant=1 --domain=person --keep=1
expect_cmd "other tenants and domains untouched" ok "^2 3$" bash -c "scripts/bmq --tenant=2 --mode=ids '$Q1' | tr '\n' ' ' | sed 's/ $//'"
expect_eq  "exactly one active snapshot per tenant and domain" "0" \
  "SELECT COUNT(*) FROM (SELECT tenant_id, domain FROM bitmap_demo.bitmap_snapshot WHERE state = 'active' GROUP BY 1, 2 HAVING COUNT(*) <> 1) d;"

echo "== tenant isolation: a reader of tenant 2 through the query role"
run_sql "DROP USER IF EXISTS $READER CASCADE;" > /dev/null
run_sql "CREATE USER $READER; GRANT bitmap_demo_query TO $READER; ALTER USER $READER DEFAULT ROLE bitmap_demo_query;
         INSERT INTO bitmap_demo.bitmap_reader VALUES ('$READER', 2); COMMIT;" > /dev/null
as_reader() { VSQL_USER=$READER VSQL_PASSWORD='' "$@"; }
reader_sql() { printf '%s\n' "$1" | VSQL_USER=$READER VSQL_PASSWORD='' vsql -X -A -t -q 2>&1 | tr '\n' ' ' | sed 's/ *$//'; }
out=$(reader_sql "SELECT CURRENT_USER();")
[ "$out" = "$READER" ] && pass "reader connects" || fail "reader connects" "$READER" "$out"
out=$(reader_sql "SELECT COUNT(*) FROM bitmap_demo.bitmap_index;")
grep -q "Permission denied" <<< "$out" && pass "reader: index table denied" || fail "reader: index table denied" "Permission denied" "$out"
out=$(reader_sql "SELECT COUNT(*) FROM bitmap_demo.user_profile;")
grep -q "Permission denied" <<< "$out" && pass "reader: source table denied" || fail "reader: source table denied" "Permission denied" "$out"
out=$(reader_sql "SELECT COUNT(*) FROM bitmap_demo.bitmap_snapshot;")
grep -q "Permission denied" <<< "$out" && pass "reader: manifest table denied" || fail "reader: manifest table denied" "Permission denied" "$out"
out=$(reader_sql "SELECT (SELECT COUNT(*) FROM bitmap_demo.v_bitmap_index WHERE tenant_id <> 2) || ' ' || (SELECT COUNT(*) FROM bitmap_demo.v_bitmap_index WHERE tenant_id = 2)
                  || ' ' || (SELECT COUNT(*) FROM bitmap_demo.v_bitmap_snapshot WHERE tenant_id <> 2) || ' ' || (SELECT COUNT(*) FROM bitmap_demo.v_daily_bitmap);")
want="0 $(run_sql "SELECT COUNT(*) FROM bitmap_demo.bitmap_index WHERE tenant_id = 2;") 0 0"
[ "$out" = "$want" ] && pass "reader: the views show tenant 2 only" || fail "reader: the views show tenant 2 only" "$want" "$out"
expect_cmd "reader: bmq Q1 on tenant 2" ok "^2 3 $" bash -c "VSQL_USER=$READER VSQL_PASSWORD='' scripts/bmq --tenant=2 --mode=ids '$Q1' | tr '\n' ' '"
expect_cmd "reader: bmq on tenant 1 finds nothing to read" fail "no active snapshot for tenant 1 domain person \(or the tenant is not readable" \
  as_reader scripts/bmq --tenant=1 "$Q1"
expect_cmd "reader: bmq --raw is denied" fail "Permission denied" as_reader scripts/bmq --tenant=2 --snapshot=1 --raw "$Q1"
run_sql "DELETE FROM bitmap_demo.bitmap_reader WHERE user_name = '$READER'; COMMIT; DROP USER $READER CASCADE;" > /dev/null

finish_tests test_lifecycle

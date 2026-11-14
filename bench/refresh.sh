#!/usr/bin/env bash
# Refresh benchmark of the person index: one change batch, applied incrementally and built in full.
#
#   bench/refresh.sh --tenant=N --fraction=F [--spread=random|recent] [--report=mixed|touch|delta]
#                    [--work-source=900] [--seed=1] [--keep] [--steps=all|apply]
#
# The active person snapshot of the tenant is the base (its source snapshot and watermark are
# kept). A fraction F of the people (0 < F <= 1) changes; --spread=random picks them by a hash of
# the entity ID (spread over every chunk, like activity of existing users), --spread=recent picks
# the highest entity IDs (recent sign-ups, few chunks). Half of them (by another hash) change their
# profile (consent flips; unknown consent becomes true), the other half change interests (lose
# their alphabetically first topic, gain one topic they do not hold). The changed data are written
# as source snapshot --work-source (a copy of the base's source with the changes) and reported as
# the next change batch:
#   mixed  profile changes as touch, interest changes as add/remove (default)
#   touch  every changed person as touch
#   delta  every change as add/remove of the affected predicates
# Then, timed by scripts/snapshot.sh: a full build of the new state, apply with --validate=touched
# (compared, then discarded), and apply with full validation; both incremental results must equal
# the full build byte for byte (index and daily sets). Everything is removed again (snapshots, batch, work
# source) and the tables are purged, unless --keep. One "refresh: ..." line per step and a final
# one. Exit status 1 if a step fails or the results differ. Connection: the VSQL_* variables.
# --steps=apply: only the apply with full validation (no full build, no comparison), e.g. as the
# background command of a measured workload (refresh under load, plan D13 P4); not published.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib_sql.sh

TENANT=""; FRACTION=""; SPREAD=random; REPORT=mixed; WORK=900; SEED=1; KEEP=no; STEPS=all
for arg in "$@"; do
    case "$arg" in
        --tenant=*)      TENANT="${arg#*=}" ;;
        --fraction=*)    FRACTION="${arg#*=}" ;;
        --spread=*)      SPREAD="${arg#*=}" ;;
        --report=*)      REPORT="${arg#*=}" ;;
        --work-source=*) WORK="${arg#*=}" ;;
        --seed=*)        SEED="${arg#*=}" ;;
        --keep)          KEEP=yes ;;
        --steps=*)       STEPS="${arg#*=}" ;;
        -h|--help)       sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "refresh.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
for v in "$TENANT" "$WORK" "$SEED"; do
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "refresh.sh: --tenant, --work-source, --seed: integers" >&2; exit 2; }
done
[[ "$FRACTION" =~ ^(0?\.[0-9]+|1(\.0*)?)$ ]] && [ "$(echo "$FRACTION > 0" | bc)" = 1 ] \
    || { echo "refresh.sh: --fraction is a number in (0, 1]" >&2; exit 2; }
case "$SPREAD" in random|recent) ;; *) echo "refresh.sh: --spread is random or recent" >&2; exit 2 ;; esac
case "$REPORT" in mixed|touch|delta) ;; *) echo "refresh.sh: --report is mixed, touch or delta" >&2; exit 2 ;; esac
case "$STEPS" in all|apply) ;; *) echo "refresh.sh: --steps is all or apply" >&2; exit 2 ;; esac

VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { printf '%s\n' "$1" | "${VSQL[@]}"; }
now() { date +%s.%N; }
elapsed() { printf '%.2f' "$(echo "$(now) - $1" | bc)"; }
SNAP=scripts/snapshot.sh
M=bitmap_demo.bitmap_snapshot

base=$(q "SELECT snapshot_id || '|' || source_snapshot_id || '|' || TO_CHAR(source_watermark, 'YYYY-MM-DD HH24:MI:SS') || '|' || batch_id
          FROM $M WHERE tenant_id = $TENANT AND domain = 'person' AND state = 'active'")
[ -n "$base" ] || { echo "refresh.sh: tenant $TENANT has no active person snapshot" >&2; exit 1; }
IFS='|' read -r BASE SRC WM B0 <<< "$base"
BATCH=$((B0 + 1))
[ "$WORK" != "$SRC" ] || { echo "refresh.sh: --work-source equals the base's source snapshot" >&2; exit 2; }
[ "$(q "SELECT (SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT AND snapshot_id = $WORK)
             + (SELECT COUNT(*) FROM bitmap_demo.user_interest WHERE tenant_id = $TENANT AND snapshot_id = $WORK)
             + (SELECT COUNT(*) FROM bitmap_demo.bitmap_change WHERE tenant_id = $TENANT AND domain = 'person' AND batch_id = $BATCH)")" = 0 ] \
    || { echo "refresh.sh: source snapshot $WORK or batch $BATCH of tenant $TENANT already has rows" >&2; exit 1; }
USERS=$(q "SELECT COUNT(*) FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT AND snapshot_id = $SRC")
N=$(printf '%.0f' "$(echo "$USERS * $FRACTION" | bc -l)")
[ "$N" -ge 1 ] || { echo "refresh.sh: fraction $FRACTION of $USERS people is no one" >&2; exit 2; }
echo "refresh: step=start tenant=$TENANT base_snapshot=$BASE source=$SRC watermark='$WM' batch=$BATCH people=$USERS" \
     "fraction=$FRACTION changed=$N spread=$SPREAD report=$REPORT seed=$SEED"

cleanup() {
    [ "$KEEP" = yes ] && return 0
    local s
    for s in $(q "SELECT snapshot_id FROM $M WHERE tenant_id = $TENANT AND domain = 'person'
                    AND state IN ('building', 'verified') AND source_snapshot_id = $WORK"); do
        $SNAP discard --tenant="$TENANT" --domain=person --snapshot="$s" > /dev/null || true
    done
    q "DELETE FROM bitmap_demo.bitmap_change WHERE tenant_id = $TENANT AND domain = 'person' AND batch_id = $BATCH;
       DELETE FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT AND snapshot_id = $WORK;
       DELETE FROM bitmap_demo.user_interest WHERE tenant_id = $TENANT AND snapshot_id = $WORK; COMMIT;" > /dev/null
    q "SELECT PURGE_TABLE('bitmap_demo.user_profile'); SELECT PURGE_TABLE('bitmap_demo.user_interest');
       SELECT PURGE_TABLE('bitmap_demo.bitmap_change'); SELECT PURGE_TABLE('bitmap_demo.bitmap_index');
       SELECT PURGE_TABLE('bitmap_demo.bitmap_predicate'); SELECT PURGE_TABLE('bitmap_demo.daily_bitmap');" > /dev/null
}
trap cleanup EXIT

# ---- 1. the changed source and the change batch (the source system's work, timed apart) -------
if [ "$SPREAD" = random ]; then
    pick="HASH(entity_id, $SEED) % 1000000000 < $(printf '%.0f' "$(echo "$FRACTION * 1000000000" | bc -l)")"
else
    pick="entity_id IN (SELECT entity_id FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT AND snapshot_id = $SRC
                        ORDER BY entity_id DESC LIMIT $N)"
fi
topic_of() { echo "CASE $1 WHEN 0 THEN 'sports' WHEN 1 THEN 'finance' ELSE 't' || $1 END"; }
case "$REPORT" in
    touch) prof="touch"; intr="touch" ;;
    delta) prof="delta"; intr="delta" ;;
    mixed) prof="touch"; intr="delta" ;;
esac
t0=$(now)
q "CREATE LOCAL TEMP TABLE rf_pick ON COMMIT PRESERVE ROWS AS
     SELECT entity_id, consent, HASH(entity_id, $SEED + 1) % 2 AS kind
     FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT AND snapshot_id = $SRC AND $pick;
   CREATE LOCAL TEMP TABLE rf_rm ON COMMIT PRESERVE ROWS AS
     SELECT i.entity_id, MIN(i.topic) AS topic FROM bitmap_demo.user_interest i JOIN rf_pick p ON p.entity_id = i.entity_id AND p.kind = 1
     WHERE i.tenant_id = $TENANT AND i.snapshot_id = $SRC GROUP BY 1;
   CREATE LOCAL TEMP TABLE rf_add ON COMMIT PRESERVE ROWS AS
     SELECT c.entity_id, c.topic FROM (SELECT entity_id, $(topic_of "(HASH(entity_id, $SEED + 2) % 500)") AS topic FROM rf_pick WHERE kind = 1) c
     WHERE NOT EXISTS (SELECT 1 FROM bitmap_demo.user_interest i
                       WHERE i.tenant_id = $TENANT AND i.snapshot_id = $SRC AND i.entity_id = c.entity_id AND i.topic = c.topic);
   INSERT /*+DIRECT*/ INTO bitmap_demo.user_profile (tenant_id, snapshot_id, entity_id, country, age, consent, suspended)
     SELECT u.tenant_id, $WORK, u.entity_id, u.country, u.age,
            CASE WHEN p.kind = 0 THEN COALESCE(NOT u.consent, TRUE) ELSE u.consent END, u.suspended
     FROM bitmap_demo.user_profile u LEFT JOIN rf_pick p ON p.entity_id = u.entity_id
     WHERE u.tenant_id = $TENANT AND u.snapshot_id = $SRC;
   INSERT /*+DIRECT*/ INTO bitmap_demo.user_interest (tenant_id, snapshot_id, entity_id, topic)
     SELECT i.tenant_id, $WORK, i.entity_id, i.topic FROM bitmap_demo.user_interest i
     LEFT JOIN rf_rm r ON r.entity_id = i.entity_id AND r.topic = i.topic
     WHERE i.tenant_id = $TENANT AND i.snapshot_id = $SRC AND r.entity_id IS NULL
     UNION ALL SELECT $TENANT, $WORK, entity_id, topic FROM rf_add;
   INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_change (tenant_id, domain, batch_id, seq, op, predicate, entity_id)
     SELECT $TENANT, 'person', $BATCH, ROW_NUMBER() OVER (ORDER BY entity_id, op, predicate), op, predicate, entity_id FROM (
       SELECT entity_id, 'touch' AS op, NULL::VARCHAR(80) AS predicate FROM rf_pick
         WHERE (kind = 0 AND '$prof' = 'touch') OR (kind = 1 AND '$intr' = 'touch')
       UNION ALL SELECT entity_id, 'remove', CASE WHEN consent THEN 'consent_true' ELSE 'consent_false' END FROM rf_pick
         WHERE kind = 0 AND '$prof' = 'delta' AND consent IS NOT NULL
       UNION ALL SELECT entity_id, 'add', CASE WHEN COALESCE(NOT consent, TRUE) THEN 'consent_true' ELSE 'consent_false' END FROM rf_pick
         WHERE kind = 0 AND '$prof' = 'delta'
       UNION ALL SELECT entity_id, 'remove', 'topic_' || topic FROM rf_rm WHERE '$intr' = 'delta'
       UNION ALL SELECT entity_id, 'add', 'topic_' || topic FROM rf_add WHERE '$intr' = 'delta') c;
   COMMIT;
   SELECT 'refresh: step=changes profile_changes=' || (SELECT COUNT(*) FROM rf_pick WHERE kind = 0)
          || ' topics_removed=' || (SELECT COUNT(*) FROM rf_rm) || ' topics_added=' || (SELECT COUNT(*) FROM rf_add)
          || ' change_rows=' || (SELECT COUNT(*) FROM bitmap_demo.bitmap_change WHERE tenant_id = $TENANT AND domain = 'person' AND batch_id = $BATCH)
          || ' touched_people=' || (SELECT COUNT(*) FROM bitmap_demo.bitmap_change WHERE tenant_id = $TENANT AND domain = 'person' AND batch_id = $BATCH AND op = 'touch')
          || ' touched_chunks=' || (SELECT COUNT(DISTINCT entity_id >> 16) FROM bitmap_demo.bitmap_change WHERE tenant_id = $TENANT AND domain = 'person' AND batch_id = $BATCH AND op = 'touch')
          || ' chunks=' || (SELECT COUNT(DISTINCT entity_id >> 16) FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT AND snapshot_id = $SRC);"
echo "refresh: step=source_and_batch s=$(elapsed "$t0") (copy of the source with the changes; not index work)"
q "SELECT ANALYZE_STATISTICS('bitmap_demo.bitmap_change');" > /dev/null
snapline() { grep '^snapshot: ' <<< "$1" | tail -n 1; }

if [ "$STEPS" = apply ]; then
    t1=$(now)
    out=$($SNAP apply --tenant="$TENANT" --domain=person --batch="$BATCH" --source-snapshot="$WORK" 2>&1) \
        || { echo "$out" | tail -n 5; echo "refresh: step=apply_full failed" >&2; exit 1; }
    echo "refresh: step=apply_full $(snapline "$out")"
    grep -E '^  batch: ' <<< "$out" | sed 's/^  /refresh: /'
    echo "refresh: step=done tenant=$TENANT fraction=$FRACTION spread=$SPREAD report=$REPORT batch=$BATCH steps=apply apply_s=$(elapsed "$t1")"
    exit 0
fi

# ---- 2. full build, incremental with touched-only validation, incremental with full validation --
# Order: the full build first, then the two applies (an apply is replayed, not rebuilt, while a
# verified snapshot of the same base and batch exists, so the touched-only one is compared with the
# full build and discarded before the apply with full validation).
snapno() { sed -E 's/.* snapshot=([0-9]+) .*/\1/' <<< "$1"; }
i="SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = $TENANT AND domain = 'person' AND snapshot_id"
d="SELECT day, channel, chunk_id, payload FROM bitmap_demo.daily_bitmap WHERE tenant_id = $TENANT AND domain = 'person' AND snapshot_id"
diff_of() {   # rows of index and daily sets that differ between snapshots $1 and $2, both directions
    q "SELECT (SELECT COUNT(*) FROM ($i = $1 EXCEPT $i = $2) a) + (SELECT COUNT(*) FROM ($i = $2 EXCEPT $i = $1) b)
            + (SELECT COUNT(*) FROM ($d = $1 EXCEPT $d = $2) c) + (SELECT COUNT(*) FROM ($d = $2 EXCEPT $d = $1) e)"
}
out=$($SNAP build --tenant="$TENANT" --domain=person --source-snapshot="$WORK" --batch="$BATCH" --watermark="$WM" --daily 2>&1) \
    || { echo "$out" | tail -n 5; echo "refresh: step=build_full failed" >&2; exit 1; }
l=$(snapline "$out"); S_F=$(snapno "$l")
echo "refresh: step=build_full $l"
out=$($SNAP apply --tenant="$TENANT" --domain=person --batch="$BATCH" --source-snapshot="$WORK" --validate=touched 2>&1) \
    || { echo "$out" | tail -n 5; echo "refresh: step=apply_touched failed" >&2; exit 1; }
l=$(snapline "$out"); S_T=$(snapno "$l")
echo "refresh: step=apply_touched $l"
grep -E '^  (ok|FAIL) ' <<< "$out" | sed 's/^/refresh: check /'
dt=$(diff_of "$S_T" "$S_F")
$SNAP discard --tenant="$TENANT" --domain=person --snapshot="$S_T" > /dev/null
out=$($SNAP apply --tenant="$TENANT" --domain=person --batch="$BATCH" --source-snapshot="$WORK" 2>&1) \
    || { echo "$out" | tail -n 5; echo "refresh: step=apply_full failed" >&2; exit 1; }
l=$(snapline "$out"); S_I=$(snapno "$l")
echo "refresh: step=apply_full $l"
grep -E '^  batch: ' <<< "$out" | sed 's/^  /refresh: /'
di=$(diff_of "$S_I" "$S_F")

# ---- 3. result ----------------------------------------------------------------------------------
equal=no; [ "$dt" = 0 ] && [ "$di" = 0 ] && equal=yes
echo "refresh: step=done tenant=$TENANT fraction=$FRACTION spread=$SPREAD report=$REPORT batch=$BATCH" \
     "snapshots_full_touched_incremental=$S_F,$S_T,$S_I differing_rows_touched=$dt differing_rows_incremental=$di equal=$equal"
[ "$equal" = yes ]

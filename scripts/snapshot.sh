#!/usr/bin/env bash
# Snapshot lifecycle of the bitmap index: build, validate, publish, retire, purge.
# docs/LIFECYCLE.md explains the states and the guarantees.
#
#   scripts/snapshot.sh build    --tenant=N --domain=D --watermark=TS [--snapshot=S|next]
#                                [--source-snapshot=P] [--batch=B] [--chunk-bits=16] [--daily]
#                                [--via-membership | --aggregate] [--pool=NAME] [--deep] [--publish]
#   scripts/snapshot.sh apply    --tenant=N --domain=D [--batch=B] [--from=S] [--snapshot=T|next]
#                                [--source-snapshot=P] [--watermark=TS] [--recompute=f1,f2]
#                                [--deep] [--validate=full|touched] [--publish]
#   scripts/snapshot.sh validate --tenant=N --domain=D --snapshot=S [--deep]
#   scripts/snapshot.sh publish  --tenant=N --domain=D --snapshot=S
#   scripts/snapshot.sh purge    --tenant=N --domain=D [--keep=1]
#   scripts/snapshot.sh discard  --tenant=N --domain=D --snapshot=S
#   scripts/snapshot.sh status   [--tenant=N] [--domain=D]
#
# build     full build of snapshot S (default: next free number) from source snapshot P (default
#           S) at the watermark; --daily adds the daily sets (domain person); --batch records the
#           last change batch the source reflects (default 0). Rerunning it on a snapshot that is
#           still building (a failed attempt) starts it again; any later state is final.
#           --aggregate builds with the aggregate function (unfenced deployments; the fast
#           path, see scripts/build_index.sh), --pool names the resource pool of the build.
# apply     incremental build of a new snapshot from snapshot --from (default: the active one):
#           change batch B (it must follow the batch of the base), a new watermark or source
#           snapshot (default: those of the base), or both. Chunks of touched entities are rebuilt
#           from the source, add/remove changes are applied as (base ANDNOT removed) OR added
#           with the last change winning, families that depend on the watermark are rebuilt when
#           it moves, --recompute rebuilds whole families, every other row is copied. Applying a
#           batch that the active snapshot already reflects does nothing.
# validate  checks a snapshot against its source (runs at the end of build and apply): one row
#           per key, every family of the catalog built, every name in exactly one family, the
#           predicate list, chunk width and checksum of every payload, and the cardinality of
#           every (predicate, chunk) and (day, channel, chunk) against native SQL; --deep also
#           compares every set ID by ID. Success: state verified. Failure: state building.
#           apply --validate=touched compares only the changed parts with native SQL (touched
#           chunks, (predicate, chunk) pairs of add/remove changes, families and daily sets
#           rebuilt in full) and requires every other row to equal the base snapshot byte for
#           byte; a source change the batch does not report is then not detected (--deep
#           always validates in full).
# publish   makes a verified (or a retired) snapshot the active one in one transaction; the
#           previous active snapshot becomes retired and stays readable.
# purge     deletes retired snapshots except the --keep most recently retired ones.
# discard   deletes a snapshot that was never published (building or verified).
#
# Connection: vsql reads VSQL_HOST, VSQL_PORT, VSQL_USER, VSQL_PASSWORD and VSQL_DATABASE.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib_sql.sh

usage() { sed -n '2,45p' "$0"; }
CMD="${1:-}"
[ $# -gt 0 ] && shift
TENANT=""; DOMAIN=""; SNAPSHOT=""; SOURCE=""; WM=""; BATCH=""; FROM=""; CB=16; DAILY=no
VIA=no; DEEP=no; PUBLISH=no; KEEP=1; RECOMPUTE=""; VALIDATE=full; AGG=no; POOL=""
# Scope of a touched-only validation, set by apply: base snapshot, batch, families rebuilt in
# full, daily sets rebuilt in full (yes/no). Empty base: full validation.
VT_BASE=""; VT_BATCH=""; VT_REC=""; VT_DAILY_REC=no
for arg in "$@"; do
    case "$arg" in
        --tenant=*)          TENANT="${arg#*=}" ;;
        --domain=*)          DOMAIN="${arg#*=}" ;;
        --snapshot=*)        SNAPSHOT="${arg#*=}" ;;
        --source-snapshot=*) SOURCE="${arg#*=}" ;;
        --watermark=*)       WM="${arg#*=}" ;;
        --batch=*)           BATCH="${arg#*=}" ;;
        --from=*)            FROM="${arg#*=}" ;;
        --chunk-bits=*)      CB="${arg#*=}" ;;
        --recompute=*)       RECOMPUTE="${arg#*=}" ;;
        --keep=*)            KEEP="${arg#*=}" ;;
        --daily)             DAILY=yes ;;
        --via-membership)    VIA=yes ;;
        --aggregate)         AGG=yes ;;
        --pool=*)            POOL="${arg#*=}" ;;
        --deep)              DEEP=yes ;;
        --publish)           PUBLISH=yes ;;
        --validate=*)        VALIDATE="${arg#*=}" ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "snapshot.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
die() { echo "snapshot.sh: $*" >&2; exit 1; }
int_re='^[0-9]+$'
for v in "$TENANT" "$SOURCE" "$BATCH" "$FROM" "$CB" "$KEEP"; do
    [ -z "$v" ] || [[ "$v" =~ $int_re ]] || { echo "snapshot.sh: numbers expected: $v" >&2; exit 2; }
done
# The index tables hold VARBINARY(16384) payloads (sql/schema.sql): enough for 16 chunk bits, not for
# 17 or 18 (up to 32 KB per chunk). Refuse here instead of failing at the first insert.
[ "$CB" -ge 8 ] && [ "$CB" -le 16 ] \
    || { echo "snapshot.sh: --chunk-bits must be 8 to 16: the index tables store VARBINARY(16384) payloads" >&2; exit 2; }
[ -z "$SNAPSHOT" ] || [ "$SNAPSHOT" = next ] || [[ "$SNAPSHOT" =~ $int_re ]] || { echo "snapshot.sh: --snapshot must be a number or next" >&2; exit 2; }
[ -z "$DOMAIN" ] || [[ "$DOMAIN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "snapshot.sh: bad --domain" >&2; exit 2; }
[ -z "$RECOMPUTE" ] || [[ "$RECOMPUTE" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || { echo "snapshot.sh: bad --recompute" >&2; exit 2; }
[ -z "$WM" ] || ts_literal "$WM" > /dev/null || exit 2
case "$VALIDATE" in
    full) ;;
    touched) [ "$CMD" = apply ] || { echo "snapshot.sh: --validate=touched applies to apply only" >&2; exit 2; } ;;
    *) echo "snapshot.sh: --validate is full or touched" >&2; exit 2 ;;
esac

VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { printf '%s\n' "$1" | "${VSQL[@]}"; }                  # rows, '|' between columns
sqlrun() { printf '%s\n' "$1" | "${VSQL[@]}" 2>&1; }        # output and errors, for messages
errline() {   # the first error message of vsql output, else its last line
    local e
    e=$(grep -m 1 -E 'ERROR|INTERNAL' <<< "$1" | sed -E 's/^.*(ERROR|INTERNAL) [0-9]+: *//' || true)
    [ -n "$e" ] || e=$(tail -n 1 <<< "$1")
    printf '%s' "$e"
}

need() {   # need VAR:option ...: stop if an option is missing
    local p v
    for p in "$@"; do
        v="${p%%:*}"
        [ -n "${!v}" ] || { echo "snapshot.sh $CMD: --${p#*:} is required" >&2; exit 2; }
    done
}

MANIFEST=bitmap_demo.bitmap_snapshot
key() { echo "tenant_id = $TENANT AND domain = '$DOMAIN' AND snapshot_id = $1"; }

# manifest S: "state|source|watermark|batch|chunk_bits|families" or nothing.
manifest() {
    q "SELECT state, source_snapshot_id, source_watermark, batch_id, chunk_bits, families
       FROM $MANIFEST WHERE $(key "$1")"
}
set_note() {   # set_note S TEXT [STATE]: note (and state) of a snapshot
    local st=""
    [ -n "${3:-}" ] && st="state = '$3', "
    q "UPDATE $MANIFEST SET $st note = $(sql_literal "${2:0:1990}") WHERE $(key "$1"); COMMIT;" > /dev/null
}
data_tables="bitmap_index daily_bitmap bitmap_predicate bitmap_membership"

# claim S|next BASE BATCH: lock the manifest, refuse a snapshot that is past building, delete rows
# of an earlier attempt, and register the snapshot as building, in one transaction. "next" takes
# the next free number under the lock. Sets SNAPSHOT (and SOURCE when it was empty).
claim() {
    local s="$1" base="$2" batch="$3" del="" t out sid src
    if [ "$s" = next ]; then
        sid="COALESCE(MAX(snapshot_id), 0) + 1"
        src="${SOURCE:-$sid}"
        for t in $data_tables; do
            del+="DELETE FROM bitmap_demo.$t WHERE tenant_id = $TENANT AND domain = '$DOMAIN'
                    AND snapshot_id = (SELECT MAX(snapshot_id) FROM $MANIFEST WHERE tenant_id = $TENANT AND domain = '$DOMAIN');"$'\n'
        done
        out=$(sqlrun "LOCK TABLE $MANIFEST IN EXCLUSIVE MODE;
INSERT INTO $MANIFEST (tenant_id, domain, snapshot_id, source_snapshot_id, source_watermark, batch_id,
                       base_snapshot_id, chunk_bits, state, families, built_at, note)
SELECT $TENANT, '$DOMAIN', $sid, $src, $(ts_literal "$WM"), $batch, $base, $CB, 'building', '', GETUTCDATE(), 'building'
FROM $MANIFEST WHERE tenant_id = $TENANT AND domain = '$DOMAIN';
$del
SELECT MAX(snapshot_id) FROM $MANIFEST WHERE tenant_id = $TENANT AND domain = '$DOMAIN';
COMMIT;") || die "$(errline "$out")"
        SNAPSHOT=$(tail -n 1 <<< "$out")
        SOURCE="${SOURCE:-$SNAPSHOT}"
        return 0
    fi
    for t in $data_tables; do del+="DELETE FROM bitmap_demo.$t WHERE $(key "$s");"$'\n'; done
    out=$(sqlrun "LOCK TABLE $MANIFEST IN EXCLUSIVE MODE;
SELECT CASE WHEN COUNT(*) = 0 OR MAX(state) = 'building' THEN 'ok'
            ELSE THROW_ERROR('snapshot $s of tenant $TENANT domain $DOMAIN is ' || MAX(state) || ': a built snapshot is never changed') END
FROM $MANIFEST WHERE $(key "$s");
$del
DELETE FROM $MANIFEST WHERE $(key "$s");
INSERT INTO $MANIFEST (tenant_id, domain, snapshot_id, source_snapshot_id, source_watermark, batch_id,
                       base_snapshot_id, chunk_bits, state, families, built_at, note)
VALUES ($TENANT, '$DOMAIN', $s, ${SOURCE:-$s}, $(ts_literal "$WM"), $batch, $base, $CB, 'building', '', GETUTCDATE(), 'building');
COMMIT;") || die "$(errline "$out")"
    SNAPSHOT="$s"; SOURCE="${SOURCE:-$s}"
}

# fail S MESSAGE: record the failure on the manifest and stop.
fail() { set_note "$1" "$2" building; die "snapshot $1 of tenant $TENANT domain $DOMAIN: $2 (not published)"; }

# ---- validate --------------------------------------------------------------------------------

# check NAME SQL: SQL returns "count|sample"; count 0 is a pass. An SQL error is a failure too.
PROBLEMS=()
check() {
    local out n
    out=$(sqlrun "$2") || { PROBLEMS+=("$1: $(errline "$out")"); echo "  FAIL  $1: $(errline "$out")"; return 0; }
    out=$(tail -n 1 <<< "$out")   # notices come first
    n="${out%%|*}"
    if [ "$n" = 0 ]; then echo "  ok    $1"; else PROBLEMS+=("$1: $n (${out#*|})"); echo "  FAIL  $1: $n (${out#*|})"; fi
}

cmd_validate() {
    need TENANT:tenant DOMAIN:domain SNAPSHOT:snapshot
    local s="$SNAPSHOT" m state src wm cb fams cat missing="" extra="" f scope pscope native expanded nd daily=no
    m=$(manifest "$s"); [ -n "$m" ] || die "no snapshot $s for tenant $TENANT domain $DOMAIN"
    IFS='|' read -r state src wm _ cb fams <<< "$m"
    echo "validate snapshot $s of tenant $TENANT domain $DOMAIN (source snapshot $src, watermark $wm, state $state)"
    PROBLEMS=()
    # families: built = catalog (+ daily)
    cat=$(catalog_families "$TENANT" "$DOMAIN")
    for f in $cat; do [[ ",$fams," == *",$f,"* ]] || missing+=" $f"; done
    for f in ${fams//,/ }; do
        [ "$f" = daily ] && { daily=yes; continue; }
        grep -qxF -- "$f" <<< "$cat" || extra+=" $f"
    done
    if [ -z "$missing$extra" ]; then echo "  ok    families complete: ${fams:-none}"
    else
        [ -n "$missing" ] && { PROBLEMS+=("families of the catalog not built:$missing"); echo "  FAIL  families of the catalog not built:$missing"; }
        [ -n "$extra" ] && { PROBLEMS+=("families not in the catalog:$extra"); echo "  FAIL  families not in the catalog:$extra"; }
    fi
    scope="tenant_id = $TENANT AND snapshot_id = $s AND domain = '$DOMAIN'"
    pscope="i.tenant_id = $TENANT AND i.snapshot_id = $s AND i.domain = '$DOMAIN'"
    check "one row per index key" "SELECT COUNT(*) || '|' || COALESCE(MIN(predicate || ' chunk ' || chunk_id), '') FROM (
        SELECT predicate, chunk_id FROM bitmap_demo.bitmap_index WHERE $scope GROUP BY 1, 2 HAVING COUNT(*) > 1) d"
    check "every name in exactly one certified family" "SELECT COUNT(*) || '|' || COALESCE(MIN(predicate || ': ' || n || ' families'), '') FROM (
        SELECT i.predicate, COUNT(f.family) AS n, MAX(f.family) AS family
        FROM (SELECT DISTINCT tenant_id, domain, predicate FROM bitmap_demo.bitmap_index WHERE $scope) i
        LEFT JOIN bitmap_demo.bitmap_family f ON f.tenant_id = i.tenant_id AND f.domain = i.domain AND REGEXP_LIKE(i.predicate, f.name_pattern)
        GROUP BY i.predicate) d
      WHERE n <> 1 OR ',' || $(sql_literal "$fams") || ',' NOT LIKE '%,' || family || ',%'"
    check "predicate list = index (family, chunks, cardinality, bytes)" "SELECT COUNT(*) || '|' || COALESCE(MIN(predicate), '') FROM (
        (SELECT p.predicate, p.family, p.chunks, p.cardinality, p.bytes FROM bitmap_demo.bitmap_predicate p
         WHERE p.tenant_id = $TENANT AND p.snapshot_id = $s AND p.domain = '$DOMAIN'
         EXCEPT
         SELECT i.predicate, MAX(f.family), COUNT(*), SUM(vbitmap.bm_cardinality(i.payload)), SUM(LENGTH(i.payload))
         FROM bitmap_demo.bitmap_index i
         JOIN bitmap_demo.bitmap_family f ON f.tenant_id = i.tenant_id AND f.domain = i.domain AND REGEXP_LIKE(i.predicate, f.name_pattern)
         WHERE $pscope GROUP BY i.predicate)
        UNION ALL
        (SELECT i.predicate, MAX(f.family), COUNT(*), SUM(vbitmap.bm_cardinality(i.payload)), SUM(LENGTH(i.payload))
         FROM bitmap_demo.bitmap_index i
         JOIN bitmap_demo.bitmap_family f ON f.tenant_id = i.tenant_id AND f.domain = i.domain AND REGEXP_LIKE(i.predicate, f.name_pattern)
         WHERE $pscope GROUP BY i.predicate
         EXCEPT
         SELECT p.predicate, p.family, p.chunks, p.cardinality, p.bytes FROM bitmap_demo.bitmap_predicate p
         WHERE p.tenant_id = $TENANT AND p.snapshot_id = $s AND p.domain = '$DOMAIN')) d"
    check "chunk width $cb in every payload header" "SELECT COUNT(*) || '|' || COALESCE(MIN(predicate || ' chunk ' || chunk_id), '') FROM (
        SELECT predicate, chunk_id FROM bitmap_demo.bitmap_index WHERE $scope
          AND vbitmap.bm_info(payload) NOT LIKE '% chunk_bits=$cb %'
        UNION ALL
        SELECT channel, chunk_id FROM bitmap_demo.daily_bitmap WHERE $scope
          AND vbitmap.bm_info(payload) NOT LIKE '% chunk_bits=$cb %') d"
    # Touched-only validation (apply --validate=touched): the native comparison covers the changed
    # parts only (chunks touched by the batch, (predicate, chunk) pairs of its add/remove changes,
    # families and daily sets rebuilt in full); every other row must equal the base snapshot byte
    # for byte, and the base was validated against its own source. A source change that the batch
    # does not report is not seen: that is the price of not reading the whole source.
    # Fingerprint of a payload for the comparison with the base: its length and its 16-byte header,
    # whose CRC-32C covers header and body (docs/FORMAT.md). Comparing whole payloads (EXCEPT over
    # some 500 MB at 10 M people) cost more than the full validation it was meant to replace.
    local fp="LENGTH(payload) AS len, SUBSTR(payload, 1, 16) AS head"
    local touched=no tch="" keys="" rec_in="''" daily_in="FALSE"
    if [ -n "$VT_BASE" ] && [ "$DEEP" = no ]; then
        touched=yes
        local br="bitmap_demo.bitmap_change WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND batch_id = ${VT_BATCH:--1}"
        tch="SELECT DISTINCT entity_id >> $cb AS chunk_id FROM $br AND op = 'touch'"
        keys="SELECT DISTINCT predicate, entity_id >> $cb AS chunk_id FROM $br AND op IN ('add', 'remove')"
        for f in ${VT_REC//,/ }; do rec_in+=",'$f'"; done
        [ "$VT_DAILY_REC" = yes ] && daily_in="TRUE"
        local rebuilt="${VT_REC//,/, }"
        [ "$VT_DAILY_REC" = yes ] && rebuilt+="${rebuilt:+, }daily"
        echo "  scope: touched only (base snapshot $VT_BASE, batch ${VT_BATCH:-none}, rebuilt in full: ${rebuilt:-none})"
    fi
    # idx_rows SNAPSHOT: index rows with their family and whether they are inside the changed parts
    idx_rows() {
        if [ "$touched" = no ]; then
            echo "SELECT i.predicate, i.chunk_id, i.payload, TRUE AS in_scope FROM bitmap_demo.bitmap_index i
                  WHERE i.tenant_id = $TENANT AND i.snapshot_id = $1 AND i.domain = '$DOMAIN'"
        else
            echo "SELECT i.predicate, i.chunk_id, i.payload,
                         (p.family IN ($rec_in) OR t.chunk_id IS NOT NULL OR k.chunk_id IS NOT NULL) AS in_scope
                  FROM bitmap_demo.bitmap_index i
                  JOIN bitmap_demo.bitmap_predicate p ON p.tenant_id = i.tenant_id AND p.snapshot_id = i.snapshot_id
                                                     AND p.domain = i.domain AND p.predicate = i.predicate
                  LEFT JOIN ($tch) t ON t.chunk_id = i.chunk_id
                  LEFT JOIN ($keys) k ON k.predicate = i.predicate AND k.chunk_id = i.chunk_id
                  WHERE i.tenant_id = $TENANT AND i.snapshot_id = $1 AND i.domain = '$DOMAIN'"
        fi
    }
    # daily_rows SNAPSHOT: the same for the daily sets (inside: touched chunks, or all if rebuilt)
    daily_rows() {
        if [ "$touched" = no ]; then
            echo "SELECT d.day, d.channel, d.chunk_id, d.payload, TRUE AS in_scope FROM bitmap_demo.daily_bitmap d
                  WHERE d.tenant_id = $TENANT AND d.snapshot_id = $1 AND d.domain = '$DOMAIN'"
        else
            echo "SELECT d.day, d.channel, d.chunk_id, d.payload, ($daily_in OR t.chunk_id IS NOT NULL) AS in_scope
                  FROM bitmap_demo.daily_bitmap d LEFT JOIN ($tch) t ON t.chunk_id = d.chunk_id
                  WHERE d.tenant_id = $TENANT AND d.snapshot_id = $1 AND d.domain = '$DOMAIN'"
        fi
    }
    # The native side: every family of the manifest, evaluated on the source snapshot.
    local famlist="" nscope=""
    for f in ${fams//,/ }; do [ "$f" = daily ] || famlist+=" $f"; done
    if [ -n "$famlist" ]; then
        # shellcheck disable=SC2086
        native=$(family_union_sql "$TENANT" "$src" "$wm" "$DOMAIN" $famlist) || die "cannot read the catalog"
        if [ "$touched" = yes ]; then
            nscope="LEFT JOIN ($tch) t ON t.chunk_id = u.chunk_id
                    LEFT JOIN ($keys) k ON k.predicate = u.predicate AND k.chunk_id = u.chunk_id
                    WHERE u.family IN ($rec_in) OR t.chunk_id IS NOT NULL OR k.chunk_id IS NOT NULL"
        fi
        check "cardinality of every (predicate, chunk) = native SQL$([ "$touched" = yes ] && echo ' (changed parts)')" "SELECT COUNT(*) || '|' || COALESCE(MIN(COALESCE(n.predicate, b.predicate) || ' chunk ' || COALESCE(n.chunk_id, b.chunk_id)
                                     || ': native ' || COALESCE(n.c, 0) || ', index ' || COALESCE(b.c, 0)), '') FROM
        (SELECT u.predicate, u.chunk_id, COUNT(DISTINCT u.entity_id) AS c
         FROM (SELECT family, predicate, entity_id, entity_id >> $cb AS chunk_id FROM ($native) u0) u $nscope GROUP BY 1, 2) n
        FULL OUTER JOIN
        (SELECT predicate, chunk_id, vbitmap.bm_cardinality(payload) AS c FROM ($(idx_rows "$s")) x WHERE in_scope) b
        ON b.predicate = n.predicate AND b.chunk_id = n.chunk_id
        WHERE n.c IS NULL OR b.c IS NULL OR n.c <> b.c"
        if [ "$touched" = yes ]; then
            check "outside the changed parts: equal to base snapshot $VT_BASE (length + header with CRC-32C)" "SELECT COUNT(*) || '|' || COALESCE(MIN(predicate || ' chunk ' || chunk_id), '') FROM (
                (SELECT predicate, chunk_id, $fp FROM ($(idx_rows "$s")) a WHERE NOT in_scope
                 EXCEPT SELECT predicate, chunk_id, $fp FROM ($(idx_rows "$VT_BASE")) b WHERE NOT in_scope)
                UNION ALL
                (SELECT predicate, chunk_id, $fp FROM ($(idx_rows "$VT_BASE")) b WHERE NOT in_scope
                 EXCEPT SELECT predicate, chunk_id, $fp FROM ($(idx_rows "$s")) a WHERE NOT in_scope)) d"
        fi
        if [ "$DEEP" = yes ]; then
            expanded="SELECT predicate, entity_id FROM (SELECT predicate, vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW)
                      FROM bitmap_demo.bitmap_index WHERE $scope) x"
            nd="SELECT DISTINCT predicate, entity_id FROM ($native) u"
            check "every set = native SQL, ID by ID (deep)" "SELECT COUNT(*) || '|' || COALESCE(MIN(predicate || ' ' || entity_id), '') FROM (
                ((SELECT * FROM ($nd) a) EXCEPT (SELECT * FROM ($expanded) b))
                UNION ALL
                ((SELECT * FROM ($expanded) b) EXCEPT (SELECT * FROM ($nd) a))) d"
        fi
    fi
    if [ "$daily" = yes ]; then
        local ev="SELECT event_ts::DATE AS day, channel, user_id FROM bitmap_demo.event_log
                  WHERE tenant_id = $TENANT AND event_ts < $(ts_literal "$wm")" escope=""
        [ "$touched" = yes ] && escope="LEFT JOIN ($tch) t ON t.chunk_id = e.chunk_id WHERE $daily_in OR t.chunk_id IS NOT NULL"
        check "one row per daily key" "SELECT COUNT(*) || '|' || COALESCE(MIN(day || ' ' || channel || ' chunk ' || chunk_id), '') FROM (
            SELECT day, channel, chunk_id FROM bitmap_demo.daily_bitmap WHERE $scope GROUP BY 1, 2, 3 HAVING COUNT(*) > 1) d"
        check "cardinality of every (day, channel, chunk) = native SQL$([ "$touched" = yes ] && echo ' (changed parts)')" "SELECT COUNT(*) || '|' || COALESCE(MIN(COALESCE(n.day, b.day) || ' ' || COALESCE(n.channel, b.channel)
                                     || ' chunk ' || COALESCE(n.chunk_id, b.chunk_id) || ': native ' || COALESCE(n.c, 0) || ', index ' || COALESCE(b.c, 0)), '') FROM
            (SELECT e.day, e.channel, e.chunk_id, COUNT(DISTINCT e.user_id) AS c
             FROM (SELECT day, channel, user_id, user_id >> $cb AS chunk_id FROM ($ev) e0) e $escope GROUP BY 1, 2, 3) n
            FULL OUTER JOIN
            (SELECT day, channel, chunk_id, vbitmap.bm_cardinality(payload) AS c FROM ($(daily_rows "$s")) x WHERE in_scope) b
            ON b.day = n.day AND b.channel = n.channel AND b.chunk_id = n.chunk_id
            WHERE n.c IS NULL OR b.c IS NULL OR n.c <> b.c"
        if [ "$touched" = yes ]; then
            check "daily sets outside the changed parts: equal to base snapshot $VT_BASE (length + header with CRC-32C)" "SELECT COUNT(*) || '|' || COALESCE(MIN(day || ' ' || channel || ' chunk ' || chunk_id), '') FROM (
                (SELECT day, channel, chunk_id, $fp FROM ($(daily_rows "$s")) a WHERE NOT in_scope
                 EXCEPT SELECT day, channel, chunk_id, $fp FROM ($(daily_rows "$VT_BASE")) b WHERE NOT in_scope)
                UNION ALL
                (SELECT day, channel, chunk_id, $fp FROM ($(daily_rows "$VT_BASE")) b WHERE NOT in_scope
                 EXCEPT SELECT day, channel, chunk_id, $fp FROM ($(daily_rows "$s")) a WHERE NOT in_scope)) d"
        fi
        if [ "$DEEP" = yes ]; then
            expanded="SELECT day, channel, entity_id FROM (SELECT day, channel, vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW)
                      FROM bitmap_demo.daily_bitmap WHERE $scope) x"
            nd="SELECT DISTINCT day, channel, user_id FROM ($ev) e"
            check "every daily set = native SQL, ID by ID (deep)" "SELECT COUNT(*) || '|' || COALESCE(MIN(day || ' ' || channel || ' ' || user_id), '') FROM (
                ((SELECT * FROM ($nd) a) EXCEPT (SELECT * FROM ($expanded) b))
                UNION ALL
                ((SELECT * FROM ($expanded) b) EXCEPT (SELECT * FROM ($nd) a))) d"
        fi
    fi
    if [ ${#PROBLEMS[@]} -gt 0 ]; then
        case "$state" in
            building|verified) fail "$s" "validation failed: ${PROBLEMS[*]}" ;;
            *) die "snapshot $s ($state) does not validate: ${PROBLEMS[*]}" ;;
        esac
    fi
    local summary
    summary=$(q "SELECT COUNT(DISTINCT predicate) || ' predicates, ' || COUNT(*) || ' index rows, ' || COALESCE(SUM(LENGTH(payload)), 0) || ' bytes'
                 FROM bitmap_demo.bitmap_index WHERE $scope")
    [ "$daily" = yes ] && summary+=$(q "SELECT '; daily: ' || COUNT(*) || ' rows, ' || COALESCE(SUM(LENGTH(payload)), 0) || ' bytes'
                                        FROM bitmap_demo.daily_bitmap WHERE $scope")
    case "$state" in
        building|verified)
            q "UPDATE $MANIFEST SET state = 'verified', verified_at = GETUTCDATE(), note = $(sql_literal "verified: $summary")
               WHERE $(key "$s") AND state IN ('building', 'verified'); COMMIT;" > /dev/null
            echo "snapshot $s of tenant $TENANT domain $DOMAIN: verified ($summary)" ;;
        *)  echo "snapshot $s of tenant $TENANT domain $DOMAIN ($state): valid ($summary)" ;;
    esac
}

# ---- publish, purge, discard, status ---------------------------------------------------------

cmd_publish() {
    need TENANT:tenant DOMAIN:domain SNAPSHOT:snapshot
    local s="$SNAPSHOT" m out
    m=$(manifest "$s"); [ -n "$m" ] || die "no snapshot $s for tenant $TENANT domain $DOMAIN"
    if [ "${m%%|*}" = active ]; then echo "snapshot $s of tenant $TENANT domain $DOMAIN is already active"; return 0; fi
    out=$(sqlrun "LOCK TABLE $MANIFEST IN EXCLUSIVE MODE;
SELECT CASE WHEN COUNT(*) = 1 AND MAX(state) IN ('verified', 'retired') THEN 'ok'
            WHEN COUNT(*) = 0 THEN THROW_ERROR('no snapshot $s for tenant $TENANT domain $DOMAIN')
            ELSE THROW_ERROR('snapshot $s of tenant $TENANT domain $DOMAIN is ' || MAX(state) || ': only a verified or retired snapshot can be published') END
FROM $MANIFEST WHERE $(key "$s");
UPDATE $MANIFEST SET state = 'retired', retired_at = GETUTCDATE()
WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND state = 'active';
UPDATE $MANIFEST SET state = 'active', published_at = GETUTCDATE(), retired_at = NULL WHERE $(key "$s");
SELECT CASE WHEN COUNT(*) = 1 AND MAX(snapshot_id) = $s THEN 'ok' ELSE THROW_ERROR('publish: not exactly one active snapshot') END
FROM $MANIFEST WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND state = 'active';
COMMIT;") || die "$(errline "$out")"
    echo "snapshot $s of tenant $TENANT domain $DOMAIN: active"
}

cmd_purge() {
    need TENANT:tenant DOMAIN:domain
    local victims del="" t out
    victims="SELECT snapshot_id FROM (SELECT snapshot_id, ROW_NUMBER() OVER (ORDER BY retired_at DESC, snapshot_id DESC) AS rn
              FROM $MANIFEST WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND state = 'retired') r WHERE rn > $KEEP"
    local list
    list=$(q "$victims ORDER BY 1" | tr '\n' ' ')
    [ -n "${list// /}" ] || { echo "purge: nothing to purge for tenant $TENANT domain $DOMAIN (keep $KEEP retired)"; return 0; }
    for t in $data_tables; do
        del+="DELETE FROM bitmap_demo.$t WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND snapshot_id IN ($victims);"$'\n'
    done
    # The manifest rows go last: the data rows are selected while their manifest rows still exist.
    out=$(sqlrun "LOCK TABLE $MANIFEST IN EXCLUSIVE MODE;
$del
DELETE FROM $MANIFEST WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND snapshot_id IN ($victims);
COMMIT;") || die "$(errline "$out")"
    echo "purge: tenant $TENANT domain $DOMAIN: removed retired snapshots ${list% }"
}

cmd_discard() {
    need TENANT:tenant DOMAIN:domain SNAPSHOT:snapshot
    local s="$SNAPSHOT" del="" t out
    for t in $data_tables; do del+="DELETE FROM bitmap_demo.$t WHERE $(key "$s");"$'\n'; done
    out=$(sqlrun "LOCK TABLE $MANIFEST IN EXCLUSIVE MODE;
SELECT CASE WHEN COUNT(*) = 1 AND MAX(state) IN ('building', 'verified') THEN 'ok'
            WHEN COUNT(*) = 0 THEN THROW_ERROR('no snapshot $s for tenant $TENANT domain $DOMAIN')
            ELSE THROW_ERROR('snapshot $s of tenant $TENANT domain $DOMAIN is ' || MAX(state) || ': only an unpublished snapshot can be discarded') END
FROM $MANIFEST WHERE $(key "$s");
$del
DELETE FROM $MANIFEST WHERE $(key "$s");
COMMIT;") || die "$(errline "$out")"
    echo "snapshot $s of tenant $TENANT domain $DOMAIN: discarded"
}

cmd_status() {
    local w="TRUE"
    [ -n "$TENANT" ] && w+=" AND tenant_id = $TENANT"
    [ -n "$DOMAIN" ] && w+=" AND domain = '$DOMAIN'"
    printf '%s\n' "SELECT tenant_id AS tenant, domain, snapshot_id AS snapshot, state, source_snapshot_id AS source,
       source_watermark AS watermark, batch_id AS batch, base_snapshot_id AS base, families, note
FROM $MANIFEST WHERE $w ORDER BY tenant_id, domain, snapshot_id;" | vsql -X -q -v ON_ERROR_STOP=1
}

# ---- build -----------------------------------------------------------------------------------

cmd_build() {
    need TENANT:tenant DOMAIN:domain WM:watermark
    [ "$DAILY" = no ] || [ "$DOMAIN" = person ] || die "--daily applies to domain person only"
    local s out fams cat via=() how=() t0
    t0=$(date +%s.%N)
    cat=$(catalog_families "$TENANT" "$DOMAIN")
    [ -n "$cat" ] || die "no families in the catalog for tenant $TENANT domain $DOMAIN"
    claim "${SNAPSHOT:-next}" NULL "${BATCH:-0}"
    s="$SNAPSHOT"
    echo "snapshot $s of tenant $TENANT domain $DOMAIN: building from source snapshot $SOURCE at $WM"
    [ "$VIA" = yes ] && via=(--via-membership)
    [ "$AGG" = yes ] && how+=(--aggregate)
    [ -n "$POOL" ] && how+=(--pool="$POOL")
    out=$(scripts/build_index.sh --tenant="$TENANT" --snapshot="$s" --source-snapshot="$SOURCE" --watermark="$WM" \
          --domain="$DOMAIN" --chunk-bits="$CB" "${via[@]}" "${how[@]}" 2>&1) || fail "$s" "build failed: $(errline "$out")"
    fams=$(echo "$cat" | paste -s -d, -)
    if [ "$DAILY" = yes ]; then
        out=$(scripts/build_index.sh --daily --tenant="$TENANT" --snapshot="$s" --watermark="$WM" --chunk-bits="$CB" \
              "${how[@]}" 2>&1) || fail "$s" "daily build failed: $(errline "$out")"
        fams+=",daily"
    fi
    q "UPDATE $MANIFEST SET families = $(sql_literal "$fams"), note = 'built' WHERE $(key "$s") AND state = 'building'; COMMIT;" > /dev/null
    printf '  built in %.1f s\n' "$(echo "$(date +%s.%N) - $t0" | bc)"
    finish build "$s" "$t0"
}

# ---- apply -----------------------------------------------------------------------------------

cmd_apply() {
    need TENANT:tenant DOMAIN:domain
    local m state src0 wm0 b0 fams0 nb active prev s t0 out
    t0=$(date +%s.%N)
    if [ -z "$FROM" ]; then
        FROM=$(q "SELECT snapshot_id FROM $MANIFEST WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND state = 'active'")
        [ -n "$FROM" ] || die "no active snapshot for tenant $TENANT domain $DOMAIN (use --from)"
    fi
    m=$(manifest "$FROM"); [ -n "$m" ] || die "no snapshot $FROM for tenant $TENANT domain $DOMAIN"
    IFS='|' read -r state src0 wm0 b0 CB fams0 <<< "$m"
    case "$state" in verified|active|retired) ;; *) die "base snapshot $FROM is $state" ;; esac
    SOURCE="${SOURCE:-$src0}"; WM="${WM:-$wm0}"
    nb="$b0"
    if [ -n "$BATCH" ]; then
        active=$(q "SELECT snapshot_id || '|' || batch_id FROM $MANIFEST WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND state = 'active'")
        if [ -n "$active" ] && [ "${active#*|}" -ge "$BATCH" ]; then
            echo "batch $BATCH is already applied: active snapshot ${active%|*} reflects batches up to ${active#*|}; nothing to do"
            return 0
        fi
        [ "$BATCH" -eq $((b0 + 1)) ] || die "batch $BATCH does not follow batch $b0 of snapshot $FROM (batches are applied in order)"
        [ "$(q "SELECT COUNT(*) FROM bitmap_demo.bitmap_change WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND batch_id = $BATCH")" != 0 ] \
            || die "batch $BATCH has no changes for tenant $TENANT domain $DOMAIN"
        nb="$BATCH"
    fi
    # An earlier run of the same apply: verified means done (replay), building means retry.
    prev=$(q "SELECT snapshot_id || '|' || state FROM $MANIFEST
              WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND base_snapshot_id = $FROM AND batch_id = $nb
                AND source_snapshot_id = $SOURCE AND source_watermark = $(ts_literal "$WM") AND state IN ('building', 'verified')
              ORDER BY snapshot_id DESC LIMIT 1")
    if [ "${prev#*|}" = verified ]; then
        echo "already built: snapshot ${prev%|*} (verified) = snapshot $FROM + batch $nb at $WM; nothing to do"
        SNAPSHOT="${prev%|*}"; [ "$PUBLISH" = no ] || cmd_publish
        return 0
    fi
    if [ -n "$prev" ]; then SNAPSHOT="${prev%|*}"; fi

    # What is rebuilt: families whose definition uses the watermark (when it moves), families of
    # the catalog that the base lacks, --recompute; the daily sets when the watermark moves.
    local cat moved rec="" keep="" f daily=no daily_rec=no
    cat=$(catalog_families "$TENANT" "$DOMAIN")
    moved=$(q "SELECT CASE WHEN $(ts_literal "$WM") = $(ts_literal "$wm0") THEN 0 ELSE 1 END")
    local wmfam=""
    [ "$moved" = 1 ] && wmfam=$(q "SELECT family FROM bitmap_demo.bitmap_family WHERE tenant_id = $TENANT AND domain = '$DOMAIN'
                                   AND definition LIKE '%\${watermark}%'")
    [[ ",$fams0," == *",daily,"* ]] && daily=yes
    [[ ",$RECOMPUTE," == *",daily,"* ]] && { [ "$daily" = yes ] || die "--recompute=daily: the base has no daily sets"; daily_rec=yes; }
    [ "$daily" = yes ] && [ "$moved" = 1 ] && daily_rec=yes
    for f in ${RECOMPUTE//,/ }; do
        [ "$f" = daily ] || grep -qxF -- "$f" <<< "$cat" || die "--recompute: no family $f in the catalog"
    done
    for f in $cat; do
        if grep -qxF -- "$f" <<< "$wmfam" || [[ ",$fams0," != *",$f,"* ]] || [[ ",$RECOMPUTE," == *",$f,"* ]]; then rec+="${rec:+,}$f"
        else keep+="${keep:+,}$f"; fi
    done
    local keep_in="''" mask=$(( (1 << CB) - 1 ))
    for f in ${keep//,/ }; do keep_in+=",'$f'"; done
    local batchrows="bitmap_demo.bitmap_change WHERE tenant_id = $TENANT AND domain = '$DOMAIN' AND batch_id = ${BATCH:--1}"
    local touched="SELECT DISTINCT entity_id >> $CB FROM $batchrows AND op = 'touch'"

    claim "${SNAPSHOT:-next}" "$FROM" "$nb"
    s="$SNAPSHOT"
    echo "snapshot $s of tenant $TENANT domain $DOMAIN: building from snapshot $FROM${BATCH:+ + batch $BATCH} (source snapshot $SOURCE at $WM)"
    [ -n "$rec" ] && echo "  rebuilt in full: $rec"
    [ "$daily_rec" = yes ] && echo "  rebuilt in full: daily sets"

    # 1. checks of the batch, resolved add/remove changes, delta rows and copies: one session.
    local copy_daily=""
    [ "$daily" = yes ] && [ "$daily_rec" = no ] && copy_daily="INSERT /*+DIRECT*/ INTO bitmap_demo.daily_bitmap (tenant_id, snapshot_id, day, channel, domain, chunk_id, payload)
  SELECT tenant_id, $s, day, channel, domain, chunk_id, payload FROM bitmap_demo.daily_bitmap
  WHERE tenant_id = $TENANT AND snapshot_id = $FROM AND domain = '$DOMAIN' AND chunk_id NOT IN (SELECT chunk_id FROM vb_touched);"
    out=$(sqlrun "CREATE LOCAL TEMP TABLE vb_touched ON COMMIT PRESERVE ROWS AS
  SELECT DISTINCT entity_id >> $CB AS chunk_id FROM $batchrows AND op = 'touch';
SELECT CASE WHEN COUNT(*) = 0 THEN 'ok' ELSE THROW_ERROR('batch ${BATCH:-}: ' || MIN(problem)) END FROM (
  SELECT 'unknown op ' || op AS problem FROM $batchrows AND op NOT IN ('add', 'remove', 'touch')
  UNION ALL SELECT 'add or remove without predicate (seq ' || seq || ')' FROM $batchrows AND op IN ('add', 'remove') AND predicate IS NULL
  UNION ALL SELECT 'negative entity ID ' || entity_id FROM $batchrows AND entity_id < 0
  UNION ALL SELECT 'seq ' || seq || ' used twice' FROM $batchrows GROUP BY seq HAVING COUNT(*) > 1) p;
-- last change wins per (predicate, entity)
CREATE LOCAL TEMP TABLE vb_change ON COMMIT PRESERVE ROWS AS
  SELECT c.predicate, c.entity_id >> $CB AS chunk_id, c.entity_id & $mask AS local_id, c.op,
         COUNT(f.family) AS families, MAX(f.family) AS family
  FROM (SELECT predicate, entity_id, op, ROW_NUMBER() OVER (PARTITION BY predicate, entity_id ORDER BY seq DESC) AS rn
        FROM $batchrows AND op IN ('add', 'remove')) c
  LEFT JOIN bitmap_demo.bitmap_family f
    ON f.tenant_id = $TENANT AND f.domain = '$DOMAIN' AND REGEXP_LIKE(c.predicate, f.name_pattern)
  WHERE c.rn = 1
  GROUP BY 1, 2, 3, 4;
SELECT CASE WHEN COUNT(*) = 0 THEN 'ok' ELSE THROW_ERROR('batch ${BATCH:-}: predicate ' || MIN(predicate) || ' matches ' || MIN(families) || ' families of the catalog') END
FROM vb_change WHERE families <> 1;
-- changes of recomputed families and touched chunks are left to the rebuild from the source
CREATE LOCAL TEMP TABLE vb_delta ON COMMIT PRESERVE ROWS AS
  SELECT k.predicate, k.chunk_id,
         vbitmap.bm_or(vbitmap.bm_andnot(COALESCE(b.payload, vbitmap.bm_empty()), COALESCE(r.payload, vbitmap.bm_empty())),
                       COALESCE(a.payload, vbitmap.bm_empty())) AS payload
  FROM (SELECT DISTINCT predicate, chunk_id FROM vb_change
        WHERE family IN ($keep_in) AND chunk_id NOT IN (SELECT chunk_id FROM vb_touched)) k
  LEFT JOIN (SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
             WHERE tenant_id = $TENANT AND snapshot_id = $FROM AND domain = '$DOMAIN') b
    ON b.predicate = k.predicate AND b.chunk_id = k.chunk_id
  LEFT JOIN (SELECT * FROM (SELECT vbitmap.bm_build(predicate, chunk_id, local_id USING PARAMETERS chunk_bits = $CB)
                            OVER (PARTITION BY predicate, chunk_id) FROM vb_change WHERE op = 'add') x) a
    ON a.predicate = k.predicate AND a.chunk_id = k.chunk_id
  LEFT JOIN (SELECT * FROM (SELECT vbitmap.bm_build(predicate, chunk_id, local_id USING PARAMETERS chunk_bits = $CB)
                            OVER (PARTITION BY predicate, chunk_id) FROM vb_change WHERE op = 'remove') x) r
    ON r.predicate = k.predicate AND r.chunk_id = k.chunk_id;
INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_index (tenant_id, snapshot_id, domain, predicate, chunk_id, payload)
  SELECT $TENANT, $s, '$DOMAIN', predicate, chunk_id, payload FROM vb_delta WHERE vbitmap.bm_cardinality(payload) > 0;
INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_index (tenant_id, snapshot_id, domain, predicate, chunk_id, payload)
  SELECT i.tenant_id, $s, i.domain, i.predicate, i.chunk_id, i.payload
  FROM bitmap_demo.bitmap_index i
  JOIN bitmap_demo.bitmap_predicate p
    ON p.tenant_id = i.tenant_id AND p.snapshot_id = i.snapshot_id AND p.domain = i.domain AND p.predicate = i.predicate
  WHERE i.tenant_id = $TENANT AND i.snapshot_id = $FROM AND i.domain = '$DOMAIN'
    AND p.family IN ($keep_in)
    AND i.chunk_id NOT IN (SELECT chunk_id FROM vb_touched)
    AND NOT EXISTS (SELECT 1 FROM vb_delta d WHERE d.predicate = i.predicate AND d.chunk_id = i.chunk_id);
$copy_daily
SELECT (SELECT COUNT(*) FROM vb_touched) || '|' || (SELECT COUNT(*) FROM vb_change) || '|'
       || (SELECT COUNT(*) FROM vb_delta) || '|' || (SELECT COUNT(*) FROM bitmap_demo.bitmap_index WHERE tenant_id = $TENANT AND snapshot_id = $s AND domain = '$DOMAIN');
COMMIT;") || fail "$s" "apply failed: $(errline "$out")"
    local nt nc nd ncopy
    IFS='|' read -r nt nc nd ncopy <<< "$(tail -n 1 <<< "$out")"
    echo "  batch: $nt touched chunks, $nc resolved add/remove changes; $nd (predicate, chunk) sets changed by delta;"
    echo "  $ncopy index rows after delta and copy"

    # 2. rebuilds from the source: whole families, then the touched chunks of the other families.
    local filter="chunk_id IN ($touched)"
    if [ -n "$rec" ]; then
        out=$(scripts/build_index.sh --append --tenant="$TENANT" --snapshot="$s" --source-snapshot="$SOURCE" --watermark="$WM" \
              --domain="$DOMAIN" --chunk-bits="$CB" --families="$rec" 2>&1) || fail "$s" "rebuild failed: $(errline "$out")"
    fi
    if [ "$nt" != 0 ] && [ -n "$keep" ]; then
        out=$(scripts/build_index.sh --append --tenant="$TENANT" --snapshot="$s" --source-snapshot="$SOURCE" --watermark="$WM" \
              --domain="$DOMAIN" --chunk-bits="$CB" --families="$keep" --chunk-filter="$filter" 2>&1) || fail "$s" "rebuild of touched chunks failed: $(errline "$out")"
    fi
    if [ "$daily_rec" = yes ]; then
        out=$(scripts/build_index.sh --append --daily --tenant="$TENANT" --snapshot="$s" --watermark="$WM" --chunk-bits="$CB" 2>&1) \
            || fail "$s" "daily rebuild failed: $(errline "$out")"
    elif [ "$daily" = yes ] && [ "$nt" != 0 ]; then
        out=$(scripts/build_index.sh --append --daily --tenant="$TENANT" --snapshot="$s" --watermark="$WM" --chunk-bits="$CB" \
              --chunk-filter="$filter" 2>&1) || fail "$s" "daily rebuild of touched chunks failed: $(errline "$out")"
    fi

    # 3. predicate list (family by name pattern; validation checks it), families, statistics.
    local fams
    fams=$(echo "$cat" | paste -s -d, -)
    [ "$daily" = yes ] && fams+=",daily"
    out=$(sqlrun "INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_predicate (tenant_id, snapshot_id, domain, family, predicate, chunks, cardinality, bytes)
  SELECT i.tenant_id, i.snapshot_id, i.domain, f.family, i.predicate, COUNT(*), SUM(vbitmap.bm_cardinality(i.payload)), SUM(LENGTH(i.payload))
  FROM bitmap_demo.bitmap_index i
  JOIN bitmap_demo.bitmap_family f ON f.tenant_id = i.tenant_id AND f.domain = i.domain AND REGEXP_LIKE(i.predicate, f.name_pattern)
  WHERE i.tenant_id = $TENANT AND i.snapshot_id = $s AND i.domain = '$DOMAIN'
  GROUP BY 1, 2, 3, 4, 5;
UPDATE $MANIFEST SET families = $(sql_literal "$fams"), note = 'built' WHERE $(key "$s") AND state = 'building';
COMMIT;
SELECT ANALYZE_STATISTICS('bitmap_demo.bitmap_index', 'tenant_id, snapshot_id, domain, predicate, chunk_id');
SELECT ANALYZE_STATISTICS('bitmap_demo.bitmap_predicate');") || fail "$s" "predicate list failed: $(errline "$out")"
    printf '  built in %.1f s\n' "$(echo "$(date +%s.%N) - $t0" | bc)"
    if [ "$VALIDATE" = touched ]; then
        VT_BASE="$FROM"; VT_BATCH="$BATCH"; VT_REC="$rec"; VT_DAILY_REC="$daily_rec"
    fi
    finish apply "$s" "$t0"
}

# finish OP S T0: validate, publish if asked, and print one summary line for the benchmark
# record: "snapshot: op=OP ... build_s= validate_s= publish_s= ..." (times from T0, the start).
finish() {
    local op="$1" s="$2" t0="$3" t1 t2 t3 sizes
    t1=$(date +%s.%N)
    cmd_validate
    t2=$(date +%s.%N)
    [ "$PUBLISH" = no ] || cmd_publish
    t3=$(date +%s.%N)
    sizes=$(q "SELECT 'predicates=' || COUNT(DISTINCT predicate) || ' index_rows=' || COUNT(*) || ' index_bytes=' || COALESCE(SUM(LENGTH(payload)), 0)
               FROM bitmap_demo.bitmap_index WHERE $(key "$s")")
    sizes+=$(q "SELECT ' daily_rows=' || COUNT(*) || ' daily_bytes=' || COALESCE(SUM(LENGTH(payload)), 0)
                FROM bitmap_demo.daily_bitmap WHERE $(key "$s")")
    printf 'snapshot: op=%s tenant=%s domain=%s snapshot=%s chunk_bits=%s deep=%s validate=%s build_s=%.2f validate_s=%.2f publish_s=%.2f total_s=%.2f %s\n' \
        "$op" "$TENANT" "$DOMAIN" "$s" "$CB" "$DEEP" "$([ -n "$VT_BASE" ] && [ "$DEEP" = no ] && echo touched || echo full)" "$(echo "$t1 - $t0" | bc)" "$(echo "$t2 - $t1" | bc)" \
        "$(echo "$t3 - $t2" | bc)" "$(echo "$t3 - $t0" | bc)" "$sizes"
}

case "$CMD" in
    build)    cmd_build ;;
    apply)    cmd_apply ;;
    validate) cmd_validate ;;
    publish)  cmd_publish ;;
    purge)    cmd_purge ;;
    discard)  cmd_discard ;;
    status)   cmd_status ;;
    ""|-h|--help) usage ;;
    *) echo "snapshot.sh: unknown command: $CMD" >&2; usage >&2; exit 2 ;;
esac

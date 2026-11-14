#!/usr/bin/env bash
# Build time and size of every predicate family, one family at a time.
#
#   bench/build_report.sh --tenant=N --source-snapshot=P --watermark=TS [--domain=D]
#                         [--chunk-bits=16] [--scratch=900] [--daily]
#
# For every family of the catalog (of --domain, or of every domain), the family alone is built
# with scripts/build_index.sh into the scratch snapshot number (never in the manifest, so no
# reader sees it), timed, measured from bitmap_demo.bitmap_predicate, and deleted again. --daily
# also times the daily sets (domain person). The lifecycle build (scripts/snapshot.sh build)
# builds all families of a domain in one pass; its time is reported by that script.
# One line per family: "family: domain=... family=... build_s=... predicates=... payloads=...
# cardinality=... bytes=... bytes_per_member=...". Connection: the VSQL_* environment variables.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib_sql.sh

TENANT=""; SOURCE=""; WM=""; DOMAIN=""; CB=16; SCRATCH=900; DAILY=no
for arg in "$@"; do
    case "$arg" in
        --tenant=*)          TENANT="${arg#*=}" ;;
        --source-snapshot=*) SOURCE="${arg#*=}" ;;
        --watermark=*)       WM="${arg#*=}" ;;
        --domain=*)          DOMAIN="${arg#*=}" ;;
        --chunk-bits=*)      CB="${arg#*=}" ;;
        --scratch=*)         SCRATCH="${arg#*=}" ;;
        --daily)             DAILY=yes ;;
        -h|--help)           sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "build_report.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
for v in "$TENANT" "$SOURCE" "$CB" "$SCRATCH"; do
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "build_report.sh: --tenant, --source-snapshot, --chunk-bits, --scratch: integers" >&2; exit 2; }
done
[ -n "$WM" ] || { echo "build_report.sh: --watermark is required" >&2; exit 2; }
[[ -z "$DOMAIN" || "$DOMAIN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "build_report.sh: bad --domain" >&2; exit 2; }

VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { printf '%s\n' "$1" | "${VSQL[@]}"; }
[ "$(q "SELECT COUNT(*) FROM bitmap_demo.bitmap_snapshot WHERE tenant_id = $TENANT AND snapshot_id = $SCRATCH")" = 0 ] \
    || { echo "build_report.sh: snapshot $SCRATCH of tenant $TENANT is in the manifest; choose another --scratch" >&2; exit 1; }
clean() {
    q "DELETE FROM bitmap_demo.bitmap_index WHERE tenant_id = $TENANT AND snapshot_id = $SCRATCH;
       DELETE FROM bitmap_demo.bitmap_predicate WHERE tenant_id = $TENANT AND snapshot_id = $SCRATCH;
       DELETE FROM bitmap_demo.bitmap_membership WHERE tenant_id = $TENANT AND snapshot_id = $SCRATCH;
       DELETE FROM bitmap_demo.daily_bitmap WHERE tenant_id = $TENANT AND snapshot_id = $SCRATCH; COMMIT;" > /dev/null
}
# Deleted rows stay in the storage containers until purged; without the purge the storage report
# of the index tables would count the scratch rows.
purge() {
    clean
    q "SELECT PURGE_TABLE('bitmap_demo.bitmap_index'); SELECT PURGE_TABLE('bitmap_demo.bitmap_predicate');
       SELECT PURGE_TABLE('bitmap_demo.bitmap_membership'); SELECT PURGE_TABLE('bitmap_demo.daily_bitmap');" > /dev/null
}
clean
trap purge EXIT
elapsed() { printf '%.2f' "$(echo "$(date +%s.%N) - $1" | bc)"; }

if [ -n "$DOMAIN" ]; then domains="$DOMAIN"
else domains=$(q "SELECT DISTINCT domain FROM bitmap_demo.bitmap_family WHERE tenant_id = $TENANT ORDER BY 1"); fi
total_bytes=0
for dom in $domains; do
    for fam in $(catalog_families "$TENANT" "$dom"); do
        t0=$(date +%s.%N)
        scripts/build_index.sh --tenant="$TENANT" --snapshot="$SCRATCH" --source-snapshot="$SOURCE" --watermark="$WM" \
            --domain="$dom" --families="$fam" --chunk-bits="$CB" --replace > /dev/null
        t=$(elapsed "$t0")
        size=$(q "SELECT 'predicates=' || COUNT(*) || ' payloads=' || COALESCE(SUM(chunks), 0) || ' cardinality=' || COALESCE(SUM(cardinality), 0)
                         || ' bytes=' || COALESCE(SUM(bytes), 0)
                         || ' bytes_per_member=' || COALESCE(ROUND(SUM(bytes) / NULLIF(SUM(cardinality), 0), 3)::VARCHAR, 'na')
                  FROM bitmap_demo.bitmap_predicate WHERE tenant_id = $TENANT AND snapshot_id = $SCRATCH AND domain = '$dom'")
        echo "family: tenant=$TENANT domain=$dom family=$fam chunk_bits=$CB build_s=$t $size"
        total_bytes=$((total_bytes + $(sed -E 's/.* bytes=([0-9]+).*/\1/' <<< "$size")))
    done
done
if [ "$DAILY" = yes ]; then
    t0=$(date +%s.%N)
    scripts/build_index.sh --daily --tenant="$TENANT" --snapshot="$SCRATCH" --watermark="$WM" --chunk-bits="$CB" > /dev/null
    t=$(elapsed "$t0")
    size=$(q "SELECT 'sets=' || COUNT(DISTINCT day || channel) || ' payloads=' || COUNT(*) || ' cardinality=' || COALESCE(SUM(vbitmap.bm_cardinality(payload)), 0)
                     || ' bytes=' || COALESCE(SUM(LENGTH(payload)), 0)
              FROM bitmap_demo.daily_bitmap WHERE tenant_id = $TENANT AND snapshot_id = $SCRATCH")
    echo "family: tenant=$TENANT domain=person family=daily chunk_bits=$CB build_s=$t $size"
fi
echo "summary: tenant=$TENANT domains=$(echo $domains | tr ' ' ,) chunk_bits=$CB family_bytes_total=$total_bytes"

#!/usr/bin/env bash
# Bit-sliced sets for the benchmark: adds the family age_bits (sql/families_bitsliced.sql) to a
# person snapshot that is already built, without rebuilding it.
#
#   bench/bitsliced.sh add  --tenant=N [--snapshot=1] [--source-snapshot=S] [--aggregate] [--pool=NAME]
#   bench/bitsliced.sh drop --tenant=N [--snapshot=1]
#
# add   puts the family into the catalog of the tenant if it is missing, builds its sets with the
#       low-level builder (scripts/build_index.sh --append: the snapshot manifest is not touched;
#       --aggregate and --pool are passed on to it),
#       adds them to the predicate list, refreshes the statistics and compares the weighted set
#       sizes with SUM(age) of the source rows, and lists the storage containers of the index
#       projections. Existing age_bits sets of the snapshot are an error.
# drop  removes the sets, their predicate rows and the family.
# In a lifecycle of your own the family is simply part of the catalog before
# scripts/snapshot.sh build; this script exists so that the measured snapshot stays as it was.
# Lines: "bitsliced: op=... key=value ...". Connection: the VSQL_* environment variables.
set -euo pipefail

cd "$(dirname "$0")/.."
OP="${1:-}"; [ $# -gt 0 ] && shift
TENANT=""; SNAP=1; SRC=""; HOW=()
for arg in "$@"; do
    case "$arg" in
        --tenant=*)          TENANT="${arg#*=}" ;;
        --snapshot=*)        SNAP="${arg#*=}" ;;
        --source-snapshot=*) SRC="${arg#*=}" ;;
        --aggregate|--pool=*) HOW+=("$arg") ;;
        -h|--help)           sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "bitsliced.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
SRC=${SRC:-$SNAP}
[[ "$TENANT" =~ ^[0-9]+$ && "$SNAP" =~ ^[0-9]+$ && "$SRC" =~ ^[0-9]+$ ]] || { echo "bitsliced.sh: --tenant, --snapshot and --source-snapshot must be integers" >&2; exit 2; }
VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
q() { printf '%s\n' "$1" | "${VSQL[@]}"; }
W="tenant_id = $TENANT AND snapshot_id = $SNAP AND domain = 'person'"
BITS="$W AND predicate LIKE 'age\\_bit\\_%'"

case "$OP" in
add)
    [ "$(q "SELECT COUNT(*) FROM bitmap_demo.bitmap_index WHERE $BITS;")" = 0 ] \
        || { echo "bitsliced.sh: snapshot $SNAP of tenant $TENANT already has age_bit sets (drop them first)" >&2; exit 1; }
    [ "$(q "SELECT COUNT(*) FROM bitmap_demo.bitmap_family WHERE tenant_id = $TENANT AND domain = 'person' AND family = 'age_bits';")" != 0 ] \
        || "${VSQL[@]}" -v tenant="$TENANT" -f sql/families_bitsliced.sql > /dev/null
    t0=$(date +%s.%N)
    scripts/build_index.sh --tenant="$TENANT" --snapshot="$SNAP" --source-snapshot="$SRC" --domain=person --families=age_bits --append "${HOW[@]}"
    s=$(printf '%.2f' "$(echo "$(date +%s.%N) - $t0" | bc)")
    q "INSERT /*+DIRECT*/ INTO bitmap_demo.bitmap_predicate (tenant_id, snapshot_id, domain, family, predicate, chunks, cardinality, bytes)
         SELECT tenant_id, snapshot_id, domain, 'age_bits', predicate, COUNT(*), SUM(vbitmap.bm_cardinality(payload)), SUM(LENGTH(payload))
         FROM bitmap_demo.bitmap_index WHERE $BITS GROUP BY 1, 2, 3, 5;
       COMMIT;
       SELECT ANALYZE_STATISTICS('bitmap_demo.bitmap_index', 'tenant_id, snapshot_id, domain, predicate, chunk_id'); SELECT ANALYZE_STATISTICS('bitmap_demo.bitmap_predicate');" > /dev/null
    sum=$(q "SELECT SUM(cardinality * (1 << SPLIT_PART(predicate, '_', 3)::INT)) FROM bitmap_demo.bitmap_predicate WHERE $W AND family = 'age_bits';")
    native=$(q "SELECT SUM(age) FROM bitmap_demo.user_profile WHERE tenant_id = $TENANT AND snapshot_id = $SRC;")
    echo "bitsliced: op=add tenant=$TENANT snapshot=$SNAP source_snapshot=$SRC $(q "SELECT 'sets=' || COUNT(*) || ' payloads=' || SUM(chunks) || ' bytes=' || SUM(bytes) FROM bitmap_demo.bitmap_predicate WHERE $W AND family = 'age_bits';") build_s=$s weighted_sum=$sum native_sum=$native equal=$([ "$sum" = "$native" ] && echo yes || echo NO)"
    q "SELECT 'bitsliced: op=containers projection=' || projection_name || ' containers=' || COUNT(*) || ' rows=' || SUM(total_row_count)
       FROM v_monitor.storage_containers WHERE schema_name = 'bitmap_demo' AND projection_name ILIKE 'bitmap_index%' GROUP BY projection_name ORDER BY 1;"
    [ "$sum" = "$native" ] ;;
drop)
    q "DELETE FROM bitmap_demo.bitmap_index WHERE $BITS;
       DELETE FROM bitmap_demo.bitmap_predicate WHERE $W AND family = 'age_bits';
       DELETE FROM bitmap_demo.bitmap_family WHERE tenant_id = $TENANT AND domain = 'person' AND family = 'age_bits';
       COMMIT;" > /dev/null
    echo "bitsliced: op=drop tenant=$TENANT snapshot=$SNAP" ;;
*) echo "bitsliced.sh: first argument add or drop (see --help)" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# Freshness of the live index (scripts/live_index.sh): new tag rows are appended to bitmap_live.tag
# and the sets are up to date when the INSERT commits.
#
#   bench/live_append.sh batch  --tenant=N [--residue=5] [--export=FILE]
#   bench/live_append.sh append --tenant=N
#
# batch   (not measured) fills the staging table bitmap_live.batch_tag: about 1 % of the people
#         (entity_id mod 77 = residue, outside country IL so that the benchmark's audience answers do
#         not change) get 20 topic tags each, spread over every ID chunk and 20 topics: about 2
#         million tag rows that touch about 3,000 existing sets. --export also writes the rows as
#         TSV (tenant, snapshot, predicate, entity) for the ClickHouse side (bench/ch.sh live-batch).
# append  (measured) INSERT INTO bitmap_live.tag SELECT ... FROM the staging table; COMMIT. Then,
#         outside the timing, the size of one touched set read from the live projection is compared
#         with COUNT(DISTINCT) on the tag table.
# Lines: "append: key=value ...". Connection: the VSQL_* environment variables.
set -euo pipefail
cd "$(dirname "$0")/.."
OP="${1:-}"; [ $# -gt 0 ] && shift
TENANT=""; RES=5; EXPORT=""
for arg in "$@"; do
    case "$arg" in
        --tenant=*)  TENANT="${arg#*=}" ;;
        --residue=*) RES="${arg#*=}" ;;
        --export=*)  EXPORT="${arg#*=}" ;;
        -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "live_append.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[[ "$TENANT" =~ ^[0-9]+$ && "$RES" =~ ^[0-9]+$ ]] || { echo "live_append.sh: --tenant=N is required" >&2; exit 2; }
VSQL=(vsql -X -A -t -q -v ON_ERROR_STOP=1)
now() { date +%s.%N; }
case "$OP" in
batch)
    "${VSQL[@]}" > /dev/null <<SQL
DROP TABLE IF EXISTS bitmap_live.batch_tag;
CREATE TABLE bitmap_live.batch_tag AS
SELECT $TENANT AS tenant_id, 1 AS snapshot_id, 'person'::VARCHAR(16) AS domain,
       ('topic_t' || (10 + k.n * 7 + MOD(p.entity_id, 7))::VARCHAR)::VARCHAR(80) AS predicate, p.entity_id
FROM (SELECT entity_id FROM bitmap_demo.user_profile
      WHERE tenant_id = $TENANT AND snapshot_id = 1 AND country <> 'IL' AND MOD(entity_id, 77) = $RES) p
CROSS JOIN (SELECT ROW_NUMBER() OVER () - 1 AS n FROM (
              SELECT ts FROM (SELECT '2000-01-01'::TIMESTAMP AS t UNION ALL SELECT '2000-01-01 00:00:19'::TIMESTAMP) x
              TIMESERIES ts AS '1 second' OVER (ORDER BY t)) y) k;
SQL
    "${VSQL[@]}" -c "SELECT 'append: op=batch tenant=$TENANT residue=$RES rows=' || COUNT(*) || ' people=' || COUNT(DISTINCT entity_id)
                            || ' topics=' || COUNT(DISTINCT predicate) || ' chunks=' || COUNT(DISTINCT entity_id >> 16)
                     FROM bitmap_live.batch_tag"
    if [ -n "$EXPORT" ]; then
        "${VSQL[@]}" -F $'\t' -o "$EXPORT" -c "SELECT tenant_id, snapshot_id, predicate, entity_id FROM bitmap_live.batch_tag"
        echo "append: op=export file=$EXPORT lines=$(wc -l < "$EXPORT" | tr -d ' ')"
    fi ;;
append)
    t0=$(now)
    n=$(printf '%s\n' "INSERT /*+DIRECT*/ INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id) SELECT tenant_id, snapshot_id, domain, predicate, entity_id FROM bitmap_live.batch_tag;" "COMMIT;" | "${VSQL[@]}" | sed -n 1p)
    t1=$(now)
    p=$("${VSQL[@]}" -c "SELECT MIN(predicate) FROM bitmap_live.batch_tag")
    live=$("${VSQL[@]}" -c "SELECT SUM(vbitmap.bm_cardinality(payload)) FROM bitmap_live.bitmap_index WHERE tenant_id = $TENANT AND snapshot_id = 1 AND domain = 'person' AND predicate = '$p'")
    native=$("${VSQL[@]}" -c "SELECT COUNT(DISTINCT entity_id) FROM bitmap_live.tag WHERE tenant_id = $TENANT AND snapshot_id = 1 AND domain = 'person' AND predicate = '$p'")
    echo "append: op=append engine=vertica tenant=$TENANT rows=$n s=$(printf '%.2f' "$(echo "$t1 - $t0" | bc)") check_set=$p live=$live native=$native equal=$([ "$live" = "$native" ] && echo yes || echo NO)"
    [ "$live" = "$native" ] ;;
*) sed -n '2,17p' "$0"; exit 2 ;;
esac

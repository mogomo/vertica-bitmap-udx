#!/usr/bin/env bash
# Copies of the bitmap index and the daily sets with a chosen encoding of the payload column, for
# measuring what the encoding costs when the sets are written and when they are read.
#
#   bench/encoding_copy.sh create NAME ENCODING [TENANT,TENANT...]   (default tenants: 10,20)
#   bench/encoding_copy.sh drop
#
# create makes bitmap_enc.index_NAME (both projections of bitmap_demo.bitmap_index: sorted by
# predicate and sorted by chunk) and bitmap_enc.daily_NAME, fills each with one INSERT of every row
# of the tenants and refreshes the statistics of the key columns. ENCODING is a Vertica encoding
# type for the payload column, or "default" for no ENCODING clause. Copies made by this script
# differ in the encoding only: same rows, same projections, same number of storage containers.
# The workloads read a copy with --var index=bitmap_enc.index_NAME --var daily=bitmap_enc.daily_NAME.
# Prints the time of each INSERT, the storage per projection and a comparison with the source rows.
set -euo pipefail
export PATH=/opt/vertica/bin:$PATH
V="vsql -X -A -t -q -v ON_ERROR_STOP=1"
cmd=${1:-}
if [ "$cmd" = drop ]; then
    $V -c "DROP SCHEMA IF EXISTS bitmap_enc CASCADE"
    echo "summary: schema bitmap_enc dropped"
    exit 0
fi
[ "$cmd" = create ] && [ $# -ge 3 ] || { sed -n '2,14p' "$0"; exit 2; }
name=$2; enc=$3; tenants=${4:-10,20}
[[ $name =~ ^[a-z][a-z0-9_]{0,20}$ ]] || { echo "encoding_copy: NAME: lower-case letters, digits, underscore"; exit 2; }
[[ $enc =~ ^[A-Za-z0-9_]+$ ]] || { echo "encoding_copy: ENCODING: an encoding type or default"; exit 2; }
[[ $tenants =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "encoding_copy: tenants: numbers separated by commas"; exit 2; }
clause=""; [ "$enc" = default ] || clause=" ENCODING $enc"
I=bitmap_enc.index_$name; DY=bitmap_enc.daily_$name

$V <<SQL
CREATE SCHEMA IF NOT EXISTS bitmap_enc;
DROP TABLE IF EXISTS $I CASCADE;
DROP TABLE IF EXISTS $DY CASCADE;
CREATE TABLE $I (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, domain VARCHAR(16) NOT NULL, predicate VARCHAR(80) NOT NULL,
    chunk_id INT NOT NULL, payload VARBINARY(16384) NOT NULL$clause)
ORDER BY tenant_id, snapshot_id, domain, predicate, chunk_id
SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES;
CREATE PROJECTION ${I}_by_chunk
    (tenant_id, snapshot_id, domain, predicate, chunk_id, payload$clause) AS
SELECT tenant_id, snapshot_id, domain, predicate, chunk_id, payload FROM $I
ORDER BY tenant_id, snapshot_id, domain, chunk_id, predicate
SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES;
CREATE TABLE $DY (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, day DATE NOT NULL, channel VARCHAR(16) NOT NULL,
    domain VARCHAR(16) NOT NULL, chunk_id INT NOT NULL, payload VARBINARY(16384) NOT NULL$clause)
ORDER BY tenant_id, snapshot_id, domain, channel, day, chunk_id
SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES;
SELECT REFRESH('$I');
SQL

timed() {   # LABEL SQL: runs the statement and prints its wall time
    local t0 t1
    t0=$(date +%s.%N)
    $V -c "$2"
    t1=$(date +%s.%N)
    echo "summary: step=$1 seconds=$(echo "$t1 $t0" | awk '{printf "%.2f", $1 - $2}')"
}
timed "insert_index_${name}_two_projections" "INSERT /*+ direct */ INTO $I SELECT tenant_id, snapshot_id, domain, predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id IN ($tenants); COMMIT"
timed "insert_daily_${name}_one_projection" "INSERT /*+ direct */ INTO $DY SELECT tenant_id, snapshot_id, day, channel, domain, chunk_id, payload FROM bitmap_demo.daily_bitmap WHERE tenant_id IN ($tenants); COMMIT"
$V <<SQL > /dev/null
SELECT ANALYZE_STATISTICS('$I', 'tenant_id, snapshot_id, domain, predicate, chunk_id');
SELECT ANALYZE_STATISTICS('$DY', 'tenant_id, snapshot_id, day, channel, domain, chunk_id');
SQL
$V <<SQL
SELECT 'summary: projection=' || p.projection_name || ' payload_encoding=' || MAX(c.encoding_type) || ' up_to_date=' || MAX(p.is_up_to_date::VARCHAR)
FROM v_catalog.projections p JOIN v_catalog.projection_columns c ON c.projection_id = p.projection_id
WHERE p.projection_schema = 'bitmap_enc' AND p.anchor_table_name IN ('index_$name', 'daily_$name') AND c.projection_column_name = 'payload'
GROUP BY p.projection_name ORDER BY 1;
SELECT 'summary: stored_projection=' || projection_name || ' containers=' || COUNT(*) || ' rows=' || SUM(total_row_count) || ' mb=' || (SUM(used_bytes) / 1e6)::NUMERIC(14,1)::VARCHAR
FROM v_monitor.storage_containers WHERE schema_name = 'bitmap_enc' AND projection_name ILIKE ANY ('index\_${name}\_%', 'daily\_${name}\_%')
GROUP BY projection_name ORDER BY 1;
SELECT 'summary: table=index_$name copy_rows=' || a.n || ' source_rows=' || b.n || ' same_content=' || (a.n = b.n AND a.h = b.h)::VARCHAR
FROM (SELECT COUNT(*) AS n, SUM(HASH(tenant_id, snapshot_id, domain, predicate, chunk_id, payload) & 4294967295) AS h FROM $I) a,
     (SELECT COUNT(*) AS n, SUM(HASH(tenant_id, snapshot_id, domain, predicate, chunk_id, payload) & 4294967295) AS h FROM bitmap_demo.bitmap_index WHERE tenant_id IN ($tenants)) b;
SELECT 'summary: table=daily_$name copy_rows=' || a.n || ' source_rows=' || b.n || ' same_content=' || (a.n = b.n AND a.h = b.h)::VARCHAR
FROM (SELECT COUNT(*) AS n, SUM(HASH(tenant_id, snapshot_id, day, channel, domain, chunk_id, payload) & 4294967295) AS h FROM $DY) a,
     (SELECT COUNT(*) AS n, SUM(HASH(tenant_id, snapshot_id, day, channel, domain, chunk_id, payload) & 4294967295) AS h FROM bitmap_demo.daily_bitmap WHERE tenant_id IN ($tenants)) b;
SQL

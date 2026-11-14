#!/usr/bin/env bash
# The live index (scripts/live_index.sh): live aggregate projections that call bm_build and
# bm_union keep the sets of schema bitmap_live up to date on every load.
#
#   tests/sql/test_live.sh [--keep]
#
# Uses the fixture of tests/sql/test_fixture.sh in bitmap_demo (loads it if bitmap_demo is missing):
# tenant 1's tags and events are loaded into bitmap_live, in two pieces, and the sets read from the
# live projections are compared with the built index, with native SQL, and after an append.
# Drops and recreates schema bitmap_live; drops it at the end unless --keep.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/sql/lib.sh
KEEP=no; [ "${1:-}" = --keep ] && KEEP=yes

if [ "$(run_sql "SELECT COUNT(*) FROM v_catalog.tables WHERE table_schema = 'bitmap_demo' AND table_name = 'bitmap_predicate';")" != 1 ]; then
    echo "== bitmap_demo missing: loading the fixture"
    tests/sql/test_fixture.sh > /dev/null || exit 1
fi
LIVE="FROM bitmap_live.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person'"
Q1='country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)'

echo "== create, load"
run_file sql/drop_live.sql
expect_cmd "create with live projections" ok "projection=bitmap_index type=UDT up_to_date=t" scripts/live_index.sh create
expect_cmd "load tenant 1" ok "op=load table=tag tenant=1 domain=person rows=[1-9]" scripts/live_index.sh load --tenant=1 --watermark="$FIX_WM_PERSON"

echo "== the live sets equal the built index"
expect_eq "same (predicate, chunk) rows, byte for byte" "0|0" \
  "SELECT (SELECT COUNT(*) FROM (SELECT predicate, chunk_id, payload $LIVE
                                 EXCEPT SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person') a),
          (SELECT COUNT(*) FROM (SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person'
                                 EXCEPT SELECT predicate, chunk_id, payload $LIVE) b);"
expect_eq "q1 count on the live projection" "3" \
  "SELECT SUM(cnt) FROM (SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = '$Q1') OVER (PARTITION BY chunk_id) $LIVE) t;"
expect_eq "q1 ids on the live projection" "1 65536 4294967296" \
  "SELECT entity_id FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = '$Q1') OVER (PARTITION BY chunk_id) $LIVE) t ORDER BY 1;"
expect_eq "daily sets = COUNT(DISTINCT) per day and channel" "0" \
  "SELECT COUNT(*) FROM (
     SELECT channel, day, SUM(vbitmap.bm_cardinality(payload)) AS users FROM bitmap_live.daily_bitmap WHERE tenant_id = 1 GROUP BY 1, 2
     EXCEPT
     SELECT channel, event_ts::DATE, COUNT(DISTINCT user_id) FROM bitmap_live.event WHERE tenant_id = 1 GROUP BY 1, 2) d;"

echo "== append: the sets follow every load"
run_sql "INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id) VALUES (1, 1, 'person', 'topic_sports', 70000); INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id) VALUES (1, 1, 'person', 'topic_chess', 3);
         INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id) VALUES (1, 1, 'person', 'topic_chess', 70000); INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id) VALUES (1, 1, 'person', 'topic_chess', 3); COMMIT;" > /dev/null
expect_eq "new members and a new predicate are visible after the commit" "2" \
  "SELECT SUM(cnt) FROM (SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_chess') OVER (PARTITION BY chunk_id) $LIVE) t;"
expect_eq "every set = COUNT(DISTINCT) on the tag table" "0" \
  "SELECT COUNT(*) FROM (
     SELECT predicate, SUM(vbitmap.bm_cardinality(payload)) AS members $LIVE GROUP BY 1
     EXCEPT
     SELECT predicate, COUNT(DISTINCT entity_id) FROM bitmap_live.tag WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person' GROUP BY 1) d;"
expect_eq "one row per (predicate, chunk) when read, although loaded in pieces" "0" \
  "SELECT COUNT(*) FROM (SELECT predicate, chunk_id $LIVE GROUP BY 1, 2 HAVING COUNT(*) > 1) d;"
run_sql "INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id) VALUES (1, 1, 'person', 'topic_chess', 5); ROLLBACK;" > /dev/null
expect_eq "a rolled-back load leaves the sets unchanged" "2" \
  "SELECT SUM(vbitmap.bm_cardinality(payload)) $LIVE AND predicate = 'topic_chess';"

echo "== INSERT ... SELECT from a table, and projections built from stored rows"
run_sql "CREATE TABLE bitmap_live.staging AS SELECT tenant_id, snapshot_id, domain, 'topic_copy'::VARCHAR(80) AS predicate, entity_id
           FROM bitmap_live.tag WHERE tenant_id = 1 AND predicate = 'topic_sports';
         INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id)
           SELECT tenant_id, snapshot_id, domain, predicate, entity_id FROM bitmap_live.staging; COMMIT;" > /dev/null
expect_eq "rows appended from a sorted table reach the sets" "0" \
  "SELECT COUNT(*) FROM (
     (SELECT entity_id FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_copy') OVER (PARTITION BY chunk_id) $LIVE) a
      EXCEPT SELECT entity_id FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_sports') OVER (PARTITION BY chunk_id) $LIVE) b)
     UNION ALL
     (SELECT entity_id FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_sports') OVER (PARTITION BY chunk_id) $LIVE) c
      EXCEPT SELECT entity_id FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_copy') OVER (PARTITION BY chunk_id) $LIVE) d)) x;"
run_sql "DROP PROJECTION bitmap_live.bitmap_index; DROP PROJECTION bitmap_live.daily_bitmap;" > /dev/null
expect_cmd "projections rebuilt from the stored rows" ok "projection=bitmap_index type=UDT up_to_date=t" scripts/live_index.sh projections
expect_eq "rebuilt sets = COUNT(DISTINCT) on the tag table" "0" \
  "SELECT COUNT(*) FROM (
     SELECT predicate, SUM(vbitmap.bm_cardinality(payload)) AS members $LIVE GROUP BY 1
     EXCEPT
     SELECT predicate, COUNT(DISTINCT entity_id) FROM bitmap_live.tag WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person' GROUP BY 1) d;"

echo "== limits and ID range"
expect_error "no DELETE on the anchor table" "UPDATE/DELETE/MERGE a table with UDT projections is not supported" \
  "DELETE FROM bitmap_live.tag WHERE entity_id = 3;"
run_sql "INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id) VALUES (1, 1, 'person', 'topic_odd', -1); INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id) VALUES (1, 1, 'person', 'topic_odd', 4294967296); COMMIT;" > /dev/null
expect_eq "any 64-bit ID, negative ones included, comes back unchanged" "-1 4294967296" \
  "SELECT entity_id FROM (SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_odd') OVER (PARTITION BY chunk_id) $LIVE) t ORDER BY 1;"

[ "$KEEP" = yes ] || run_file sql/drop_live.sql
finish_tests test_live

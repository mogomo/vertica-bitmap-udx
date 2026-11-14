-- Tuned projections for the native path (benchmark, plan section 17.2). The source tables already
-- have the orders that the queries need for interests (topic, entity) and events (channel, time,
-- user); the profiles were ordered by entity only, so every profile filter scanned all rows. This
-- projection orders them by the filter columns, most selective first among the low-cardinality
-- ones, with run-length encoding on the sorted columns. The optimizer chooses between projections
-- per query (the saved plans show which one). Remove with bench/vertica_projections_drop.sql.
-- Built from the existing rows by REFRESH; the time of this script is the native "index" cost.

CREATE PROJECTION IF NOT EXISTS bitmap_demo.user_profile_by_filter (
    tenant_id ENCODING RLE, snapshot_id ENCODING RLE, country ENCODING RLE, consent ENCODING RLE,
    suspended ENCODING RLE, age ENCODING RLE, entity_id)
AS SELECT tenant_id, snapshot_id, country, consent, suspended, age, entity_id
   FROM bitmap_demo.user_profile
   ORDER BY tenant_id, snapshot_id, country, consent, suspended, age, entity_id
SEGMENTED BY HASH(entity_id) ALL NODES;

SELECT REFRESH('bitmap_demo.user_profile');
SELECT ANALYZE_STATISTICS('bitmap_demo.user_profile');

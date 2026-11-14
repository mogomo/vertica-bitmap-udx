-- The live projections of schema bitmap_live (sql/live.sql). Ordered by chunk, then predicate, so
-- that the expression functions (PARTITION BY chunk_id) read the sets of a chunk together. The
-- PARTITION BY lists name table columns only (see sql/live.sql for the reason).

CREATE PROJECTION bitmap_live.bitmap_index (tenant_id, snapshot_id, domain, chunk_id, predicate, payload) AS
SELECT tenant_id, snapshot_id, domain, chunk_id, predicate,
       vbitmap.bm_union(sq.part) OVER (PARTITION BATCH BY tenant_id, snapshot_id, domain, chunk_id, predicate) AS (payload)
FROM (SELECT tenant_id, snapshot_id, domain, chunk_id, predicate,
             vbitmap.bm_build(entity_id & 65535)
               OVER (PARTITION PREPASS BY tenant_id, snapshot_id, domain, chunk_id, predicate) AS (part)
      FROM bitmap_live.tag) sq;

CREATE PROJECTION bitmap_live.daily_bitmap (tenant_id, channel, day, chunk_id, payload) AS
SELECT tenant_id, channel, day, chunk_id,
       vbitmap.bm_union(sq.part) OVER (PARTITION BATCH BY tenant_id, channel, day, chunk_id) AS (payload)
FROM (SELECT tenant_id, channel, day, chunk_id,
             vbitmap.bm_build(user_id & 65535)
               OVER (PARTITION PREPASS BY tenant_id, channel, day, chunk_id) AS (part)
      FROM bitmap_live.event) sq;

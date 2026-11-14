-- Query role bitmap_demo_query: the reader views of schema bitmap_demo and the vbitmap functions,
-- nothing else (no index, catalog or source table). Run after sql/schema.sql and after a fresh
-- install of the library (grants survive CREATE OR REPLACE FUNCTION, not DROP LIBRARY).
-- Requires a superuser.
--
-- A reader is a database user with this role and one row per tenant in bitmap_demo.bitmap_reader:
--   CREATE USER reader_t2;  GRANT bitmap_demo_query TO reader_t2;
--   ALTER USER reader_t2 DEFAULT ROLE bitmap_demo_query;
--   INSERT INTO bitmap_demo.bitmap_reader VALUES ('reader_t2', 2); COMMIT;
-- The views run with the privileges of their owner and filter on CURRENT_USER(), so a reader
-- sees published snapshots of its own tenants only.

-- Vertica 26.3 has no CREATE ROLE IF NOT EXISTS: an existing role is not an error here (vsql
-- reports "already exists" and goes on).
\unset ON_ERROR_STOP
CREATE ROLE bitmap_demo_query;
\set ON_ERROR_STOP 1

GRANT USAGE ON SCHEMA bitmap_demo TO bitmap_demo_query;
GRANT SELECT ON bitmap_demo.v_bitmap_snapshot, bitmap_demo.v_bitmap_index, bitmap_demo.v_daily_bitmap,
                bitmap_demo.v_bitmap_predicate, bitmap_demo.v_bitmap_family TO bitmap_demo_query;
GRANT USAGE ON SCHEMA vbitmap TO bitmap_demo_query;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA vbitmap TO bitmap_demo_query;

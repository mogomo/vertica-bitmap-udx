-- Removes the aggregate functions (a fenced deployment has none).
DROP AGGREGATE FUNCTION IF EXISTS vbitmap.bm_build_agg(INT);
DROP AGGREGATE FUNCTION IF EXISTS vbitmap.bm_union_agg(VARBINARY);

-- The aggregate forms of bm_build and bm_union (src/udx/aggregates.cpp). Vertica runs user-defined
-- aggregates inside the server process only, so scripts/deploy.sh runs this file for an unfenced
-- deployment and sql/drop_aggregates.sql for a fenced one.
CREATE OR REPLACE AGGREGATE FUNCTION vbitmap.bm_build_agg AS LANGUAGE 'C++' NAME 'BmBuildAggFactory' LIBRARY vbitmap.vbitmap;
CREATE OR REPLACE AGGREGATE FUNCTION vbitmap.bm_union_agg AS LANGUAGE 'C++' NAME 'BmUnionAggFactory' LIBRARY vbitmap.vbitmap;

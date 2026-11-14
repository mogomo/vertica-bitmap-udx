-- Installs the vbitmap library and its functions in schema vbitmap.
-- Variables (set by scripts/deploy.sh): libfile (path of libvbitmap.so on the initiator node),
-- fenced (FENCED or NOT FENCED). Requires a superuser (CREATE LIBRARY).
-- Touches only schema vbitmap. The two aggregate functions are installed by
-- sql/install_aggregates.sql (unfenced deployments only).

CREATE SCHEMA IF NOT EXISTS vbitmap;
CREATE OR REPLACE LIBRARY vbitmap.vbitmap AS :libfile LANGUAGE 'C++';

CREATE OR REPLACE FUNCTION vbitmap.bm_and            AS LANGUAGE 'C++' NAME 'BmAndFactory'            LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_or             AS LANGUAGE 'C++' NAME 'BmOrFactory'             LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_xor            AS LANGUAGE 'C++' NAME 'BmXorFactory'            LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_andnot         AS LANGUAGE 'C++' NAME 'BmAndNotFactory'         LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_cardinality    AS LANGUAGE 'C++' NAME 'BmCardinalityFactory'    LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_and_cardinality AS LANGUAGE 'C++' NAME 'BmAndCardinalityFactory' LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_contains       AS LANGUAGE 'C++' NAME 'BmContainsFactory'       LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_empty          AS LANGUAGE 'C++' NAME 'BmEmptyFactory'          LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_info           AS LANGUAGE 'C++' NAME 'BmInfoFactory'           LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_version        AS LANGUAGE 'C++' NAME 'BmVersionFactory'        LIBRARY vbitmap.vbitmap :fenced;

CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_build  AS LANGUAGE 'C++' NAME 'BmBuildFactory'  LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_union  AS LANGUAGE 'C++' NAME 'BmUnionFactory'  LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_to_ids AS LANGUAGE 'C++' NAME 'BmToIdsFactory' LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_pair_count AS LANGUAGE 'C++' NAME 'BmPairCountFactory' LIBRARY vbitmap.vbitmap :fenced;

-- Expression transforms (src/engine/expr.h): one scan of the rows of a chunk, no joins.
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_count  AS LANGUAGE 'C++' NAME 'BmCountFactory'  LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_eval   AS LANGUAGE 'C++' NAME 'BmEvalFactory'   LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_ids    AS LANGUAGE 'C++' NAME 'BmIdsFactory'    LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_ids_text AS LANGUAGE 'C++' NAME 'BmIdsTextFactory' LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_facets AS LANGUAGE 'C++' NAME 'BmFacetsFactory' LIBRARY vbitmap.vbitmap :fenced;

-- Pinned sets (src/udx/pinned.h): a set kept in memory for the session and tested row by row.
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_pin AS LANGUAGE 'C++' NAME 'BmPinFactory'     LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION vbitmap.bm_pin AS LANGUAGE 'C++' NAME 'BmPinExprFactory' LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_member AS LANGUAGE 'C++' NAME 'BmMemberFactory' LIBRARY vbitmap.vbitmap :fenced;
CREATE OR REPLACE FUNCTION vbitmap.bm_unpin  AS LANGUAGE 'C++' NAME 'BmUnpinFactory'  LIBRARY vbitmap.vbitmap :fenced;

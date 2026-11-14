-- Generated people for scale tests and the benchmark, inside Vertica (no files). Run through
-- scripts/generate.sh, which passes the vsql variables tenant, snapshot, users, seed, entity_expr.
-- Every attribute is a deterministic function of HASH(seed, n, column number), where n = 0 .. users-1
-- is the person's row number in signup order; the same seed gives the same data on any database.
-- Only the entity ID depends on the ID order (scripts/generate.sh builds entity_expr from n and the
-- country index c):
--
--   signup     entity_id = n (IDs in signup order; the data of earlier versions, unchanged)
--   random     entity_id = (n * 2654435761 + 12345) mod users (a fixed permutation)
--   clustered  entity_id = rank of (c, n): people of one country get consecutive IDs
--   --id-space=wide then maps every ID e to (e div 65536) * 2^40 + (e mod 65536): the same chunks,
--   but every chunk above 0 lies above 2^32, so the sets are 64-bit sets.
--
-- bitmap_demo.gen_person keeps (n, entity_id) so that interests and events use the same people, and
-- so that the mapping can be stated and reproduced.
--
--   country    40 codes, skewed: index c = floor(40 * u^2.5), u uniform; IL (c = 0) about 23%
--   age        18 to 90 uniform, NULL 2%
--   consent    true 70%, false 29%, NULL 1%
--   suspended  true 3%, false 96%, NULL 1%

-- (bitmap_demo.gen_person is created by scripts/generate.sh when missing.)
INSERT /*+DIRECT*/ INTO bitmap_demo.gen_person (tenant_id, snapshot_id, n, entity_id)
SELECT :tenant, :snapshot, n, :entity_expr
FROM (SELECT n, FLOOR(40 * POWER(((HASH(:seed, n, 1) & 9223372036854775807) % 1000000) / 1000000.0, 2.5))::INT AS c
      FROM (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS n
            FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                  UNION ALL SELECT TIMESTAMPADD('second', :users - 1, '2000-01-01 00:00:00'::TIMESTAMP)) b
            TIMESERIES ts AS '1 second' OVER (ORDER BY t)) g) p;
COMMIT;

INSERT /*+DIRECT*/ INTO bitmap_demo.user_profile (tenant_id, snapshot_id, entity_id, country, age, consent, suspended)
SELECT :tenant, :snapshot, entity_id,
       SPLIT_PART('IL,US,DE,FR,GB,IT,ES,NL,BE,SE,NO,DK,FI,PL,CZ,AT,CH,PT,IE,GR,HU,RO,BG,HR,SK,SI,LT,LV,EE,LU,MT,CY,IS,CA,MX,BR,AR,JP,KR,AU',
                  ',', (FLOOR(40 * POWER(((HASH(:seed, n, 1) & 9223372036854775807) % 1000000) / 1000000.0, 2.5)) + 1)::INT),
       CASE WHEN (HASH(:seed, n, 2) & 9223372036854775807) % 1000 < 20 THEN NULL
            ELSE 18 + ((HASH(:seed, n, 2) & 9223372036854775807) // 1000) % 73 END,
       CASE WHEN (HASH(:seed, n, 3) & 9223372036854775807) % 100 < 1 THEN NULL
            WHEN (HASH(:seed, n, 3) & 9223372036854775807) % 100 < 71 THEN true ELSE false END,
       CASE WHEN (HASH(:seed, n, 4) & 9223372036854775807) % 100 < 1 THEN NULL
            WHEN (HASH(:seed, n, 4) & 9223372036854775807) % 100 < 4 THEN true ELSE false END
FROM bitmap_demo.gen_person
WHERE tenant_id = :tenant AND snapshot_id = :snapshot;
COMMIT;

SELECT ANALYZE_STATISTICS('bitmap_demo.gen_person');
SELECT ANALYZE_STATISTICS('bitmap_demo.user_profile');

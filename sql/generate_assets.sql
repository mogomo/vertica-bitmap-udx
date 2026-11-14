-- Generated asset state and asset sources, inside Vertica. Run through scripts/generate.sh.
-- vsql variables: tenant, snapshot, assets, blocks (= ceil(assets / 10^6)), refresh_start (quoted
-- timestamp), seed. Asset IDs are 0 .. assets-1; every attribute is a function of HASH(seed, id, column):
--
--   contains_pii  true 15%
--   deleted       true 5%
--   refreshed_at  uniform over the 60 days from refresh_start (one refreshed_YYYY_MM_DD set per day)
--   sources       1 to 3 distinct of 50 per asset, uniform: source k of asset i is (a + 7k) mod 50
--                 (7 is coprime with 50); source 0 is named ERP_A (the fixture queries apply), the
--                 others SRC_01 .. SRC_49

INSERT /*+DIRECT*/ INTO bitmap_demo.asset_state (tenant_id, snapshot_id, asset_id, contains_pii, deleted, refreshed_at)
SELECT :tenant, :snapshot, i,
       (HASH(:seed, i, 31) & 9223372036854775807) % 100 < 15,
       (HASH(:seed, i, 32) & 9223372036854775807) % 100 < 5,
       TIMESTAMPADD('second', (HASH(:seed, i, 33) & 9223372036854775807) % (60 * 86400), :refresh_start::TIMESTAMP)
FROM (SELECT a.a * 1000000 + b.b AS i
      FROM (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS a
            FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                  UNION ALL SELECT TIMESTAMPADD('second', :blocks - 1, '2000-01-01 00:00:00'::TIMESTAMP)) x
            TIMESERIES ts AS '1 second' OVER (ORDER BY t)) a
      CROSS JOIN (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS b
                  FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                        UNION ALL SELECT TIMESTAMPADD('second', 999999, '2000-01-01 00:00:00'::TIMESTAMP)) x
                  TIMESERIES ts AS '1 second' OVER (ORDER BY t)) b) ab
WHERE i < :assets;
COMMIT;

INSERT /*+DIRECT*/ INTO bitmap_demo.asset_source (tenant_id, snapshot_id, asset_id, source)
SELECT :tenant, :snapshot, s.asset_id,
       CASE WHEN src = 0 THEN 'ERP_A' ELSE 'SRC_' || LPAD(src::VARCHAR, 2, '0') END
FROM (SELECT a.asset_id,
             ((HASH(:seed, a.asset_id, 34) & 9223372036854775807) % 50 + 7 * k.k) % 50 AS src,
             k.k, 1 + (HASH(:seed, a.asset_id, 35) & 9223372036854775807) % 3 AS cnt
      FROM bitmap_demo.asset_state a
      CROSS JOIN (SELECT 0 AS k UNION ALL SELECT 1 UNION ALL SELECT 2) k
      WHERE a.tenant_id = :tenant AND a.snapshot_id = :snapshot) s
WHERE s.k < s.cnt;
COMMIT;

SELECT ANALYZE_STATISTICS('bitmap_demo.asset_state');
SELECT ANALYZE_STATISTICS('bitmap_demo.asset_source');

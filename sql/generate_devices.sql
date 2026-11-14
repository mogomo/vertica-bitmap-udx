-- Generated device state, inside Vertica. Run through scripts/generate.sh.
-- vsql variables: tenant, snapshot, devices, blocks (= ceil(devices / 10^6)), watermark (quoted
-- timestamp), seed. Device IDs are 0 .. devices-1; every attribute is a function of HASH(seed, id, column):
--
--   online       true 90%, false 10%
--   zone         20 zones A to T, uniform
--   temp_tenths  200 to 1,100 uniform (20.0 to 110.0 C)
--   changes_10m  0 to 12 uniform
--   observed_at  95%: 0 to 1,799 s before the watermark (current); 5%: 1,801 s to 4 h before it,
--                so these devices are expired at the watermark (families keep 30 minutes, sql/families.sql)

INSERT /*+DIRECT*/ INTO bitmap_demo.device_state (tenant_id, snapshot_id, device_id, online, zone, temp_tenths, changes_10m, observed_at)
SELECT :tenant, :snapshot, i,
       (HASH(:seed, i, 21) & 9223372036854775807) % 100 < 90,
       CHR(65 + ((HASH(:seed, i, 22) & 9223372036854775807) % 20)::INT),
       200 + (HASH(:seed, i, 23) & 9223372036854775807) % 901,
       (HASH(:seed, i, 24) & 9223372036854775807) % 13,
       TIMESTAMPADD('second',
                    -CASE WHEN (HASH(:seed, i, 25) & 9223372036854775807) % 100 < 95
                          THEN (HASH(:seed, i, 26) & 9223372036854775807) % 1800
                          ELSE 1801 + (HASH(:seed, i, 26) & 9223372036854775807) % 12600 END,
                    :watermark::TIMESTAMP)
FROM (SELECT a.a * 1000000 + b.b AS i
      FROM (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS a
            FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                  UNION ALL SELECT TIMESTAMPADD('second', :blocks - 1, '2000-01-01 00:00:00'::TIMESTAMP)) x
            TIMESERIES ts AS '1 second' OVER (ORDER BY t)) a
      CROSS JOIN (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS b
                  FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                        UNION ALL SELECT TIMESTAMPADD('second', 999999, '2000-01-01 00:00:00'::TIMESTAMP)) x
                  TIMESERIES ts AS '1 second' OVER (ORDER BY t)) b) ab
WHERE i < :devices;
COMMIT;

SELECT ANALYZE_STATISTICS('bitmap_demo.device_state');

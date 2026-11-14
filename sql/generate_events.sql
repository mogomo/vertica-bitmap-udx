-- Generated events of the people of (tenant, snapshot), inside Vertica. Run through
-- scripts/generate.sh. vsql variables: tenant, snapshot, users, events, blocks (= ceil(events / 10^6)),
-- days, start (quoted timestamp of the first day), user_skew, seed.
-- Event e = 0 .. events-1 (event_id = e) is a deterministic function of HASH(seed, e, column):
--
--   person    rank r = floor(users * u^user_skew), u uniform: low ranks are heavy users (with
--             user_skew 2 the busiest 1% of people make about 10% of the events); the rank is
--             spread over the people by the fixed permutation n = (r * 2654435761 + 7) mod users,
--             so heavy users are not bunched in signup order; user_id = entity_id of n.
--   day       uniform over days days from start; time of day uniform (UTC)
--   channel   web 55%, app 30%, email 10%, store 5%

INSERT /*+DIRECT*/ INTO bitmap_demo.event_log (tenant_id, event_id, user_id, event_ts, channel)
SELECT :tenant, x.e, g.entity_id,
       TIMESTAMPADD('second', x.d * 86400 + x.s, :start::TIMESTAMP), x.channel
FROM (SELECT e,
             ((FLOOR(:users * POWER(((HASH(:seed, e, 11) & 9223372036854775807) % 1000000000) / 1000000000.0, :user_skew))::INT
               * 2654435761 + 7) % :users) AS n,
             (HASH(:seed, e, 12) & 9223372036854775807) % :days AS d,
             (HASH(:seed, e, 13) & 9223372036854775807) % 86400 AS s,
             CASE WHEN (HASH(:seed, e, 14) & 9223372036854775807) % 100 < 55 THEN 'web'
                  WHEN (HASH(:seed, e, 14) & 9223372036854775807) % 100 < 85 THEN 'app'
                  WHEN (HASH(:seed, e, 14) & 9223372036854775807) % 100 < 95 THEN 'email'
                  ELSE 'store' END AS channel
      FROM (SELECT a.a * 1000000 + b.b AS e
            FROM (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS a
                  FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                        UNION ALL SELECT TIMESTAMPADD('second', :blocks - 1, '2000-01-01 00:00:00'::TIMESTAMP)) x
                  TIMESERIES ts AS '1 second' OVER (ORDER BY t)) a
            CROSS JOIN (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS b
                        FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                              UNION ALL SELECT TIMESTAMPADD('second', 999999, '2000-01-01 00:00:00'::TIMESTAMP)) x
                        TIMESERIES ts AS '1 second' OVER (ORDER BY t)) b) ab
      WHERE e < :events) x
JOIN bitmap_demo.gen_person g ON g.tenant_id = :tenant AND g.snapshot_id = :snapshot AND g.n = x.n;
COMMIT;

SELECT ANALYZE_STATISTICS('bitmap_demo.event_log');

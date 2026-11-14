-- Generated interests, skewed topic popularity (scripts/generate.sh --topic-skew=S, S > 0).
-- vsql variables: tenant, snapshot, topics (at most 1009), topics_per_user, topic_skew, seed.
-- Each person draws 2 * topics_per_user candidate topics t = floor(topics * u^S), u uniform, and keeps
-- the first topics_per_user distinct ones; topic 0 (sports) is the most popular, the share falls
-- with the topic number. Measured with 500 topics and 20 per person (200,000 people, seed 42):
--   S = 1.25: sports 13.2%, finance 10.0%, t100 4.3%, t499 3.2%
--   S = 1.5:  sports 27.9%, finance 17.5%, t100 4.6%, t499 2.7%   (the benchmark's skewed setting)
--   S = 2:    sports 61.2%, finance 32.2%, t100 4.6%, t499 2.1%
--   S = 4:    sports 99.4% (too strong to be realistic)
-- A person whose candidates repeat a lot keeps fewer topics; generate.sh reports the actual total.
-- Topic 0 is named sports, topic 1 finance, the others tN.

INSERT /*+DIRECT*/ INTO bitmap_demo.user_interest (tenant_id, snapshot_id, entity_id, topic)
SELECT :tenant, :snapshot, entity_id, DECODE(t, 0, 'sports', 1, 'finance', 't' || t)
FROM (SELECT entity_id, t, ROW_NUMBER() OVER (PARTITION BY n ORDER BY first_k) AS r
      FROM (SELECT g.n, g.entity_id,
                   LEAST(FLOOR(:topics * POWER(((HASH(:seed, g.n, 100 + k.k) & 9223372036854775807) % 1000000000) / 1000000000.0,
                                                :topic_skew))::INT, :topics - 1) AS t,
                   MIN(k.k) AS first_k
            FROM bitmap_demo.gen_person g
            CROSS JOIN (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS k
                        FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                              UNION ALL SELECT TIMESTAMPADD('second', 2 * :topics_per_user - 1, '2000-01-01 00:00:00'::TIMESTAMP)) b
                        TIMESERIES ts AS '1 second' OVER (ORDER BY t)) k
            WHERE g.tenant_id = :tenant AND g.snapshot_id = :snapshot
            GROUP BY 1, 2, 3) c) x
WHERE r <= :topics_per_user;
COMMIT;

SELECT ANALYZE_STATISTICS('bitmap_demo.user_interest');

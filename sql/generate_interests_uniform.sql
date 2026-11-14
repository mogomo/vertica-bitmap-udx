-- Generated interests, uniform topic popularity (scripts/generate.sh --topic-skew=0, the default).
-- vsql variables: tenant, snapshot, topics (at most 1009), topics_per_user, seed.
-- Exactly topics_per_user distinct topics per person: topic k of person n is (a + k * p) mod topics,
-- a uniform and p one of the primes 1009, 1013, 1019, 1021 (coprime with topics <= 1009, so the
-- topics of a person are distinct). Topic 0 is named sports, topic 1 finance (the fixture queries
-- apply), the others tN. Same data as earlier versions for the same seed and ID order signup.

INSERT /*+DIRECT*/ INTO bitmap_demo.user_interest (tenant_id, snapshot_id, entity_id, topic)
SELECT :tenant, :snapshot, entity_id,
       DECODE(t, 0, 'sports', 1, 'finance', 't' || t)
FROM (SELECT g.entity_id,
             ((HASH(:seed, g.n, 5) & 9223372036854775807) % :topics
              + k.k * CASE (HASH(:seed, g.n, 6) & 9223372036854775807) % 4
                        WHEN 0 THEN 1009 WHEN 1 THEN 1013 WHEN 2 THEN 1019 ELSE 1021 END) % :topics AS t
      FROM bitmap_demo.gen_person g
      CROSS JOIN (SELECT DATEDIFF('second', '2000-01-01 00:00:00'::TIMESTAMP, ts) AS k
                  FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t
                        UNION ALL SELECT TIMESTAMPADD('second', :topics_per_user - 1, '2000-01-01 00:00:00'::TIMESTAMP)) b
                  TIMESERIES ts AS '1 second' OVER (ORDER BY t)) k
      WHERE g.tenant_id = :tenant AND g.snapshot_id = :snapshot) x;
COMMIT;

SELECT ANALYZE_STATISTICS('bitmap_demo.user_interest');

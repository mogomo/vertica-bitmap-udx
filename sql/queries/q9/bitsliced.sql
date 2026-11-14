-- Q9 attribute totals over an audience from sets alone (family age_bits of
-- sql/families_bitsliced.sql): one bm_facets pass counts the audience inside "all", inside
-- "age_known" and inside each bit-slice set; the sum of ages is the sum of 2^b times the count of
-- bit b. No join and no row of the profile table. An empty facets prefix makes every set that is
-- read a facet; the operands of the expression come back as facets too and are not used.
SELECT people, age_known, CASE WHEN age_known > 0 THEN bit_sum END AS age_sum
FROM (
  SELECT COALESCE(SUM(CASE WHEN predicate = 'all' THEN cnt END), 0) AS people,
         COALESCE(SUM(CASE WHEN predicate = 'age_known' THEN cnt END), 0) AS age_known,
         COALESCE(SUM(CASE WHEN predicate LIKE 'age\_bit\_%'
                           THEN cnt * (1 << SPLIT_PART(predicate, '_', 3)::INT) END), 0) AS bit_sum
  FROM (
    SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS
             expr = 'country_IL & topic_sports - topic_finance', facets = '')
           OVER (PARTITION BY chunk_id)
    FROM bitmap_demo.bitmap_index
    WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person'
      AND (predicate IN ('country_IL', 'topic_sports', 'topic_finance', 'all', 'age_known')
           OR predicate LIKE 'age\_bit\_%')
  ) f
) t;

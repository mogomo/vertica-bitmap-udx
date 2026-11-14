-- Q3 disjunctive facets: the topic filter of the audience is left out (exclude = 'topic_'), so
-- every topic is counted within IL, age 25 to 54, consent, not suspended.
SELECT predicate, SUM(cnt) AS users
FROM (
  SELECT vbitmap.bm_facets(chunk_id, predicate, payload USING PARAMETERS
           expr = 'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)',
           facets = 'topic_', exclude = 'topic_')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person'
    AND (predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false') OR predicate LIKE 'topic\_%')
) t
GROUP BY predicate;

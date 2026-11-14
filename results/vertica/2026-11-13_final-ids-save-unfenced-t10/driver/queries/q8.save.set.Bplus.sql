INSERT INTO bitmap_bench.saved_set (audience, chunk_id, payload)
SELECT 'q8', chunk_id, payload FROM (
  SELECT vbitmap.bm_eval(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
) t; COMMIT;

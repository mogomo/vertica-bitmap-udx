SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'country_IL & consent_true & (topic_t10 | topic_t11 | topic_t12 | topic_t13 | topic_t14 | topic_t15)') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('country_IL','consent_true','topic_t10','topic_t11','topic_t12','topic_t13','topic_t14','topic_t15')) t;

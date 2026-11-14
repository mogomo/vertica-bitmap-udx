SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = '(topic_finance | age_25_54) & suspended_false') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('topic_finance','age_25_54','suspended_false')) t;

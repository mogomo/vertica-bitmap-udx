SELECT vbitmap.bm_ids(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance', text = true)
         OVER (PARTITION BY chunk_id)
  FROM bitmap_enc.index_zstd
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance');

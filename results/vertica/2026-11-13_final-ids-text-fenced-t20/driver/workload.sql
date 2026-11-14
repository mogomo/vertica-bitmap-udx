-- @engine vertica
-- @set device_wm=2026-11-01 12:00:00
-- @set dsnap=1
-- @set index=bitmap_demo.bitmap_index
-- @set psnap=1
-- @set src=1
-- @set tenant=20
-- @query q1.ids.text.Bplus answer=q1.ids
SELECT vbitmap.bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & age_25_54 & consent_true & suspended_false & (topic_sports | topic_finance)')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'age_25_54', 'consent_true', 'suspended_false', 'topic_sports', 'topic_finance');
-- @query q8.text.Bplus answer=q8
SELECT vbitmap.bm_ids_text(chunk_id, predicate, payload USING PARAMETERS expr =
           'country_IL & topic_sports - topic_finance')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 20 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('country_IL', 'topic_sports', 'topic_finance');

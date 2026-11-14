WITH k AS (
  SELECT predicate, chunk_id, payload FROM bitmap_demo.bitmap_index
  WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
), cohort AS (
  SELECT a.chunk_id,
         vbitmap.bm_and(vbitmap.bm_and(a.payload, b.payload),
           vbitmap.bm_and(vbitmap.bm_and(c.payload, d.payload),
             vbitmap.bm_or(COALESCE(s.payload, vbitmap.bm_empty()),
                           COALESCE(f.payload, vbitmap.bm_empty())))) AS payload
  FROM k a
  JOIN k b ON b.chunk_id = a.chunk_id AND b.predicate = 'age_25_54'
  JOIN k c ON c.chunk_id = a.chunk_id AND c.predicate = 'consent_true'
  JOIN k d ON d.chunk_id = a.chunk_id AND d.predicate = 'suspended_false'
  LEFT JOIN k s ON s.chunk_id = a.chunk_id AND s.predicate = 'topic_sports'
  LEFT JOIN k f ON f.chunk_id = a.chunk_id AND f.predicate = 'topic_finance'
  WHERE a.predicate = 'country_IL'
)
SELECT vbitmap.bm_to_ids(chunk_id, payload) OVER (PARTITION ROW) AS entity_id FROM cohort;

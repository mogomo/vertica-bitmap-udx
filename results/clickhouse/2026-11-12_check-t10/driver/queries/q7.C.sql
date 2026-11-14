WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS sp,
     bitmapCardinality(sp) AS n
SELECT predicate, bitmapAndCardinality(bm, sp) AS intersection,
       bitmapCardinality(bm) + n - intersection AS union_size,
       round(intersection / union_size, 4) AS jaccard
FROM xbench.person_bitmap
WHERE tenant_id = 10 AND snapshot_id = 1 AND startsWith(predicate, 'topic_') AND predicate != 'topic_sports';

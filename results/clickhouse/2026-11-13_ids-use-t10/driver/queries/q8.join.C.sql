WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT count() AS people, count(age) AS age_known, sum(age) AS age_sum
FROM xbench.user_profile
WHERE tenant_id = 10 AND snapshot_id = 1 AND bitmapContains(bitmapAndnot(bitmapAnd(a, s), f), entity_id);

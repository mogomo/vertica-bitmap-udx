-- @engine clickhouse
-- @set bsnap=1
-- @set device_wm=2026-11-01 12:00:00
-- @set ptable=xbench.person_bitmap
-- @set src=1
-- @set tenant=10
-- @query q8.save.set.C answer=q8.save.set
INSERT INTO xbench.saved_set (audience, bm)
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT 'q8', bitmapAndnot(bitmapAnd(a, s), f);
-- @query q8.save.ids.C answer=q8.save.ids
INSERT INTO xbench.saved_ids (audience, entity_id)
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f
SELECT 'q8', arrayJoin(bitmapToArray(bitmapAndnot(bitmapAnd(a, s), f)));

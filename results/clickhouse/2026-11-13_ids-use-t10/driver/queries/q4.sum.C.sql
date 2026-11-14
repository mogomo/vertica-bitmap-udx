SELECT count() AS ids, sum(entity_id) AS id_sum FROM (
WITH (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'online_true') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'zone_A') AS b,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'temp_ge_800') AS c,
     (SELECT groupBitmapMergeState(bm) FROM xbench.device_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'changes_gt_3') AS d
SELECT arrayJoin(bitmapToArray(bitmapAnd(bitmapAnd(a, b), bitmapAnd(c, d)))) AS entity_id);

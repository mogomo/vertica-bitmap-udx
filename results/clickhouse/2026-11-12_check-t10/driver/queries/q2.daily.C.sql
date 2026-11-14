SELECT day, groupBitmapMerge(bm) AS users
FROM xbench.daily_bitmap
WHERE tenant_id = 10 AND snapshot_id = 1 AND channel = 'web'
  AND day >= toDate('2026-10-15') AND day < toDate('2026-10-17')
GROUP BY day;

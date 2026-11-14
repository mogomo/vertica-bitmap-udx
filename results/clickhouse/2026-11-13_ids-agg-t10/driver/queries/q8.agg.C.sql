WITH (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'country_IL') AS a,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_sports') AS s,
     (SELECT groupBitmapMergeState(bm) FROM xbench.person_bitmap WHERE tenant_id = 10 AND snapshot_id = 1 AND predicate = 'topic_finance') AS f,
     bitmapAndnot(bitmapAnd(a, s), f) AS aud
SELECT bitmapCardinality(aud) AS people,
       sumIf(bitmapAndCardinality(aud, bm), predicate = 'age_known') AS age_known,
       sumIf(bitmapAndCardinality(aud, bm) * bitShiftLeft(toUInt64(1), toUInt8OrZero(substring(predicate, 9))), startsWith(predicate, 'age_bit_')) AS age_sum
FROM (SELECT predicate, groupBitmapMergeState(bm) AS bm FROM xbench.person_bitmap
      WHERE tenant_id = 10 AND snapshot_id = 1 AND (predicate = 'age_known' OR startsWith(predicate, 'age_bit_'))
      GROUP BY predicate);

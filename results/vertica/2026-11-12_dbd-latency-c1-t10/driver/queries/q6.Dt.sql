SELECT a.day || ' ' || b.day AS days, COUNT(*) AS users
FROM (SELECT DISTINCT event_ts::DATE AS day, user_id FROM bitmap_dbd.event_log
      WHERE tenant_id = 10 AND channel = 'web'
        AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-22 00:00:00') a
JOIN (SELECT DISTINCT event_ts::DATE AS day, user_id FROM bitmap_dbd.event_log
      WHERE tenant_id = 10 AND channel = 'web'
        AND event_ts >= TIMESTAMP '2026-10-15 00:00:00' AND event_ts < TIMESTAMP '2026-10-22 00:00:00') b
  ON b.user_id = a.user_id AND b.day >= a.day
GROUP BY a.day, b.day;

-- Q6 retention grid, native SQL: for every pair of days (i <= j), web users active on both.
WITH d AS (
  SELECT DISTINCT event_ts::DATE AS day, user_id
  FROM bitmap_demo.event_log
  WHERE tenant_id = ${tenant} AND channel = 'web'
)
SELECT a.day || ' ' || b.day AS days, COUNT(*) AS users
FROM d a JOIN d b ON b.user_id = a.user_id AND b.day >= a.day
GROUP BY a.day, b.day;

-- Q8 NULL trap, native SQL: "not suspended" as a complement counts people whose suspension is
-- unknown; "suspended IS FALSE" does not.
SELECT SUM(CASE WHEN suspended IS TRUE THEN 0 ELSE 1 END) AS complement,
       SUM(CASE WHEN suspended IS FALSE THEN 1 ELSE 0 END) AS explicit
FROM bitmap_demo.user_profile
WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot};

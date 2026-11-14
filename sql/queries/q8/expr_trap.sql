-- Q8 NULL trap, expression transforms: there is no unary NOT, the complement names its universe.
SELECT (SELECT COALESCE(SUM(cnt), 0) FROM (
          SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'all - suspended_true')
                 OVER (PARTITION BY chunk_id)
          FROM bitmap_demo.bitmap_index
          WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person'
            AND predicate IN ('all', 'suspended_true')) a) AS complement,
       (SELECT COALESCE(SUM(cnt), 0) FROM (
          SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'suspended_false')
                 OVER (PARTITION BY chunk_id)
          FROM bitmap_demo.bitmap_index
          WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND domain = 'person'
            AND predicate IN ('suspended_false')) b) AS explicit;

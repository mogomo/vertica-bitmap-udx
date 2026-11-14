-- Sweep workload, written by bench/make_sweep.py for tenant 10 (source snapshot 1, person index snapshot 1).
-- A: native SQL written from the expression; Bplus: the SQL of scripts/bmq --raw --echo_only.
-- @engine vertica

-- sw.n2: 2 predicates: country_IL & topic_sports
-- @query sw.n2.A answer=sw.n2 oracle
SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND (p.country = 'IL' AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic = 'sports'));

-- @query sw.n2.Bplus answer=sw.n2
SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'country_IL & topic_sports') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('country_IL','topic_sports')) t;

-- sw.n8: 8 predicates: country_IL & consent_true & (topic_t10 | topic_t11 | topic_t12 | topic_t13 | topic_t14 | topic_t15)
-- @query sw.n8.A answer=sw.n8 oracle
SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND ((p.country = 'IL' AND p.consent IS TRUE) AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic IN ('t10', 't11', 't12', 't13', 't14', 't15')));

-- @query sw.n8.Bplus answer=sw.n8
SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'country_IL & consent_true & (topic_t10 | topic_t11 | topic_t12 | topic_t13 | topic_t14 | topic_t15)') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('country_IL','consent_true','topic_t10','topic_t11','topic_t12','topic_t13','topic_t14','topic_t15')) t;

-- sw.n32: 32 predicates: country_IL & consent_true & (topic_t10 | topic_t11 | topic_t12 | topic_t13 | topic_t14 | topic_t15 | topic_t16 | topic_t17 | topic_t18 | topic_t19 | topic_t20 | topic_t21 | topic_t22 | topic_t23 | topic_t24 | topic_t25 | topic_t26 | topic_t27 | topic_t28 | topic_t29 | topic_t30 | topic_t31 | topic_t32 | topic_t33 | topic_t34 | topic_t35 | topic_t36 | topic_t37 | topic_t38 | topic_t39)
-- @query sw.n32.A answer=sw.n32 oracle
SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND ((p.country = 'IL' AND p.consent IS TRUE) AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic IN ('t10', 't11', 't12', 't13', 't14', 't15', 't16', 't17', 't18', 't19', 't20', 't21', 't22', 't23', 't24', 't25', 't26', 't27', 't28', 't29', 't30', 't31', 't32', 't33', 't34', 't35', 't36', 't37', 't38', 't39')));

-- @query sw.n32.Bplus answer=sw.n32
SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'country_IL & consent_true & (topic_t10 | topic_t11 | topic_t12 | topic_t13 | topic_t14 | topic_t15 | topic_t16 | topic_t17 | topic_t18 | topic_t19 | topic_t20 | topic_t21 | topic_t22 | topic_t23 | topic_t24 | topic_t25 | topic_t26 | topic_t27 | topic_t28 | topic_t29 | topic_t30 | topic_t31 | topic_t32 | topic_t33 | topic_t34 | topic_t35 | topic_t36 | topic_t37 | topic_t38 | topic_t39)') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('country_IL','consent_true','topic_t10','topic_t11','topic_t12','topic_t13','topic_t14','topic_t15','topic_t16','topic_t17','topic_t18','topic_t19','topic_t20','topic_t21','topic_t22','topic_t23','topic_t24','topic_t25','topic_t26','topic_t27','topic_t28','topic_t29','topic_t30','topic_t31','topic_t32','topic_t33','topic_t34','topic_t35','topic_t36','topic_t37','topic_t38','topic_t39')) t;

-- sw.s0.01: 3 predicates: topic_t8 & topic_t13 & country_IS
-- @query sw.s0.01.A answer=sw.s0.01 oracle
SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND ((EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic = 't8') AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic = 't13')) AND p.country = 'IS');

-- @query sw.s0.01.Bplus answer=sw.s0.01
SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_t8 & topic_t13 & country_IS') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('topic_t8','topic_t13','country_IS')) t;

-- sw.s1: 3 predicates: (topic_t6 | country_BR) & topic_t15
-- @query sw.s1.A answer=sw.s1 oracle
SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND ((EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic = 't6') OR p.country = 'BR') AND EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic = 't15'));

-- @query sw.s1.Bplus answer=sw.s1
SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = '(topic_t6 | country_BR) & topic_t15') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('topic_t6','country_BR','topic_t15')) t;

-- sw.s10: 3 predicates: (topic_t3 | country_KR) & consent_true
-- @query sw.s10.A answer=sw.s10 oracle
SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND ((EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic = 't3') OR p.country = 'KR') AND p.consent IS TRUE);

-- @query sw.s10.Bplus answer=sw.s10
SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = '(topic_t3 | country_KR) & consent_true') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('topic_t3','country_KR','consent_true')) t;

-- sw.s50: 3 predicates: (topic_finance | age_25_54) & suspended_false
-- @query sw.s50.A answer=sw.s50 oracle
SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p
WHERE p.tenant_id = 10 AND p.snapshot_id = 1
  AND ((EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = 10 AND i.snapshot_id = 1 AND i.entity_id = p.entity_id AND i.topic = 'finance') OR p.age BETWEEN 25 AND 54) AND p.suspended IS FALSE);

-- @query sw.s50.Bplus answer=sw.s50
SELECT COALESCE(SUM(cnt), 0) AS cnt FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = '(topic_finance | age_25_54) & suspended_false') OVER (PARTITION BY chunk_id)
  FROM bitmap_demo.bitmap_index WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person' AND predicate IN ('topic_finance','age_25_54','suspended_false')) t;

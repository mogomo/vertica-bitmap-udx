-- Optional predicate family for the tenant given as vsql variable :tenant: a numeric attribute as
-- bit slices. One set per bit of the value: age_bit_0 ... age_bit_7 hold the people whose age has
-- that bit set (ages 0 to 255; a value outside this range stops the build with an error).
--
-- With these sets the total of the attribute over any audience needs no join and no row of the
-- profile table:
--     people      = |audience AND all|
--     known ages  = |audience AND age_known|
--     sum of ages = SUM over b of 2^b * |audience AND age_bit_b|
-- which is one bm_facets pass (sql/queries/q9/bitsliced.sql); the average is sum / known ages.
-- The sets are ordinary predicates, so they also work in expressions: age_bit_7 is "128 or older",
-- age_known - age_bit_6 - age_bit_7 is "younger than 64".
--
-- Run it after sql/families.sql and before the build (scripts/snapshot.sh build includes every
-- family of the catalog). The same pattern serves any non-negative integer attribute: one set per
-- bit, as many bits as the largest value needs.
-- Columns: tenant, domain, family, name pattern (regular expression), definition.

INSERT INTO bitmap_demo.bitmap_family
SELECT :tenant, 'person', 'age_bits', '^age_bit_[0-7]$',
  'SELECT THROW_ERROR(''age outside 0 to 255: '' || age::VARCHAR), entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age NOT BETWEEN 0 AND 255
   UNION ALL
   SELECT ''age_bit_0'', entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 0 AND 255 AND ((age >> 0) & 1) = 1
   UNION ALL
   SELECT ''age_bit_1'', entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 0 AND 255 AND ((age >> 1) & 1) = 1
   UNION ALL
   SELECT ''age_bit_2'', entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 0 AND 255 AND ((age >> 2) & 1) = 1
   UNION ALL
   SELECT ''age_bit_3'', entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 0 AND 255 AND ((age >> 3) & 1) = 1
   UNION ALL
   SELECT ''age_bit_4'', entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 0 AND 255 AND ((age >> 4) & 1) = 1
   UNION ALL
   SELECT ''age_bit_5'', entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 0 AND 255 AND ((age >> 5) & 1) = 1
   UNION ALL
   SELECT ''age_bit_6'', entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 0 AND 255 AND ((age >> 6) & 1) = 1
   UNION ALL
   SELECT ''age_bit_7'', entity_id FROM bitmap_demo.user_profile
   WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 0 AND 255 AND ((age >> 7) & 1) = 1';
COMMIT;

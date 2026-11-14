-- Correctness fixture (tenant 1, snapshot 1) and an isolation tenant (tenant 2, snapshot 1).
-- Expected answers: sql/queries/README.md and tests/sql/test_fixture.sh.

-- ---- people, tenant 1: (id, country, age, consent, suspended), topics as separate rows ------
INSERT INTO bitmap_demo.user_profile
          SELECT 1, 1, 1,          'IL', 34,   true, false
UNION ALL SELECT 1, 1, 2,          'IL', 67,   true, false
UNION ALL SELECT 1, 1, 3,          'US', 41,   true, false
UNION ALL SELECT 1, 1, 4,          'IL', 27,   true, true
UNION ALL SELECT 1, 1, 7,          'IL', NULL, true, false
UNION ALL SELECT 1, 1, 65536,      'IL', 50,   true, false
UNION ALL SELECT 1, 1, 4294967296, 'IL', 45,   true, false;

INSERT INTO bitmap_demo.user_interest
          SELECT 1, 1, 1,          'sports'
UNION ALL SELECT 1, 1, 2,          'sports'
UNION ALL SELECT 1, 1, 3,          'finance'
UNION ALL SELECT 1, 1, 4,          'sports'
UNION ALL SELECT 1, 1, 4,          'finance'
UNION ALL SELECT 1, 1, 7,          'sports'
UNION ALL SELECT 1, 1, 65536,      'finance'
UNION ALL SELECT 1, 1, 4294967296, 'sports';

-- ---- people, tenant 2: the same IDs with other attributes ------------------------------------
INSERT INTO bitmap_demo.user_profile
          SELECT 2, 1, 1, 'US', 30, true,  false
UNION ALL SELECT 2, 1, 2, 'IL', 40, true,  false
UNION ALL SELECT 2, 1, 3, 'IL', 35, true,  false;

INSERT INTO bitmap_demo.user_interest
          SELECT 2, 1, 1, 'finance'
UNION ALL SELECT 2, 1, 2, 'sports'
UNION ALL SELECT 2, 1, 3, 'finance';

-- ---- events (UTC, noon), unique event IDs ----------------------------------------------------
INSERT INTO bitmap_demo.event_log
          SELECT 1, 1, 1,          '2026-11-01 12:00:00'::TIMESTAMP, 'web'
UNION ALL SELECT 1, 2, 1,          '2026-11-01 12:00:00'::TIMESTAMP, 'web'
UNION ALL SELECT 1, 3, 65536,      '2026-11-01 12:00:00'::TIMESTAMP, 'web'
UNION ALL SELECT 1, 4, 1,          '2026-11-02 12:00:00'::TIMESTAMP, 'web'
UNION ALL SELECT 1, 5, 4294967296, '2026-11-02 12:00:00'::TIMESTAMP, 'web'
UNION ALL SELECT 1, 6, 1,          '2026-11-01 12:00:00'::TIMESTAMP, 'app'
UNION ALL SELECT 1, 7, 3,          '2026-11-01 12:00:00'::TIMESTAMP, 'app'
UNION ALL SELECT 2, 1, 2,          '2026-11-01 12:00:00'::TIMESTAMP, 'web';

-- ---- devices at 2026-11-01 12:00 UTC: (id, online, zone, temp_tenths, changes_10m) ---------
INSERT INTO bitmap_demo.device_state
          SELECT 1, 1, 10, true,  'A', 830, 5, '2026-11-01 12:00:00'::TIMESTAMP
UNION ALL SELECT 1, 1, 11, true,  'A', 780, 5, '2026-11-01 12:00:00'::TIMESTAMP
UNION ALL SELECT 1, 1, 12, false, 'A', 900, 7, '2026-11-01 12:00:00'::TIMESTAMP;

-- ---- assets: (id, contains_pii, deleted, refreshed_at), each linked to ERP_A ---------------
INSERT INTO bitmap_demo.asset_state
          SELECT 1, 1, 100, true, false, '2026-10-20 00:00:00'::TIMESTAMP
UNION ALL SELECT 1, 1, 101, true, false, '2026-10-30 00:00:00'::TIMESTAMP
UNION ALL SELECT 1, 1, 102, true, true,  '2026-10-20 00:00:00'::TIMESTAMP;

INSERT INTO bitmap_demo.asset_source
          SELECT 1, 1, 100, 'ERP_A'
UNION ALL SELECT 1, 1, 101, 'ERP_A'
UNION ALL SELECT 1, 1, 102, 'ERP_A';

COMMIT;

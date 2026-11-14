-- Predicate families for the demo, for the tenant given as vsql variable :tenant.
-- Each definition returns (predicate, entity_id); ${tenant}, ${snapshot} (source snapshot) and
-- ${watermark} are replaced by the builder. NULL attributes produce no row: suspended_false is
-- built from "suspended IS FALSE", never as a complement, and "all" is the explicit universe.
-- Device state expires: an observation counts only if it is at most 30 minutes older than the
-- snapshot's watermark (and not after it), so a device that stops reporting leaves every set.
-- Columns: tenant, domain, family, name pattern (regular expression), definition.

INSERT INTO bitmap_demo.bitmap_family
-- person
          SELECT :tenant, 'person', 'universe', '^all$',
  'SELECT ''all'' AS predicate, entity_id FROM bitmap_demo.user_profile WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot}'
UNION ALL SELECT :tenant, 'person', 'country', '^country_.+$',
  'SELECT ''country_'' || country, entity_id FROM bitmap_demo.user_profile WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND country IS NOT NULL'
UNION ALL SELECT :tenant, 'person', 'age_band', '^(age_25_54|age_known)$',
  'SELECT ''age_25_54'', entity_id FROM bitmap_demo.user_profile WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age BETWEEN 25 AND 54
   UNION ALL
   SELECT ''age_known'', entity_id FROM bitmap_demo.user_profile WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND age IS NOT NULL'
UNION ALL SELECT :tenant, 'person', 'consent', '^consent_(true|false)$',
  'SELECT CASE WHEN consent THEN ''consent_true'' ELSE ''consent_false'' END, entity_id FROM bitmap_demo.user_profile WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND consent IS NOT NULL'
UNION ALL SELECT :tenant, 'person', 'suspended', '^suspended_(true|false)$',
  'SELECT CASE WHEN suspended THEN ''suspended_true'' ELSE ''suspended_false'' END, entity_id FROM bitmap_demo.user_profile WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND suspended IS NOT NULL'
UNION ALL SELECT :tenant, 'person', 'topic', '^topic_.+$',
  'SELECT ''topic_'' || topic, entity_id FROM bitmap_demo.user_interest WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot}'
-- device
UNION ALL SELECT :tenant, 'device', 'online', '^online_(true|false)$',
  'SELECT CASE WHEN online THEN ''online_true'' ELSE ''online_false'' END, device_id FROM bitmap_demo.device_state WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND online IS NOT NULL
   AND observed_at > TIMESTAMPADD(''minute'', -30, ${watermark}) AND observed_at <= ${watermark}'
UNION ALL SELECT :tenant, 'device', 'zone', '^zone_.+$',
  'SELECT ''zone_'' || zone, device_id FROM bitmap_demo.device_state WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND zone IS NOT NULL
   AND observed_at > TIMESTAMPADD(''minute'', -30, ${watermark}) AND observed_at <= ${watermark}'
UNION ALL SELECT :tenant, 'device', 'temperature', '^temp_ge_800$',
  'SELECT ''temp_ge_800'', device_id FROM bitmap_demo.device_state WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND temp_tenths >= 800
   AND observed_at > TIMESTAMPADD(''minute'', -30, ${watermark}) AND observed_at <= ${watermark}'
UNION ALL SELECT :tenant, 'device', 'changes', '^changes_gt_3$',
  'SELECT ''changes_gt_3'', device_id FROM bitmap_demo.device_state WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND changes_10m > 3
   AND observed_at > TIMESTAMPADD(''minute'', -30, ${watermark}) AND observed_at <= ${watermark}'
-- asset
UNION ALL SELECT :tenant, 'asset', 'pii', '^pii_(true|false)$',
  'SELECT CASE WHEN contains_pii THEN ''pii_true'' ELSE ''pii_false'' END, asset_id FROM bitmap_demo.asset_state WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND contains_pii IS NOT NULL'
UNION ALL SELECT :tenant, 'asset', 'deleted', '^deleted_(true|false)$',
  'SELECT CASE WHEN deleted THEN ''deleted_true'' ELSE ''deleted_false'' END, asset_id FROM bitmap_demo.asset_state WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND deleted IS NOT NULL'
UNION ALL SELECT :tenant, 'asset', 'source', '^source_.+$',
  'SELECT ''source_'' || source, asset_id FROM bitmap_demo.asset_source WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot}'
UNION ALL SELECT :tenant, 'asset', 'refreshed_day', '^refreshed_[0-9]{4}_[0-9]{2}_[0-9]{2}$',
  'SELECT ''refreshed_'' || TO_CHAR(refreshed_at, ''YYYY_MM_DD''), asset_id FROM bitmap_demo.asset_state WHERE tenant_id = ${tenant} AND snapshot_id = ${snapshot} AND refreshed_at IS NOT NULL';
COMMIT;

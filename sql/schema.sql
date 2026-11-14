-- Schema bitmap_demo: source tables, index tables, catalog and snapshot manifest.
-- Creates the schema; fails if it exists (sql/drop_schema.sql removes it).
-- All key columns are NOT NULL. Timestamps are UTC. Payload columns are VARBINARY(16384):
-- the largest payload with 16 chunk bits is 8,208 bytes (docs/FORMAT.md).
-- Single-node database: K-safety 0 (the default). On a cluster add KSAFE 1 to every table.

CREATE SCHEMA bitmap_demo;

-- ---- source tables ---------------------------------------------------------------------------

CREATE TABLE bitmap_demo.user_profile (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, entity_id INT NOT NULL,
    country VARCHAR(2), age INT, consent BOOLEAN, suspended BOOLEAN)
ORDER BY tenant_id, snapshot_id, entity_id
SEGMENTED BY HASH(entity_id) ALL NODES;

CREATE TABLE bitmap_demo.user_interest (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, entity_id INT NOT NULL,
    topic VARCHAR(40) NOT NULL)
ORDER BY tenant_id, snapshot_id, topic, entity_id
SEGMENTED BY HASH(entity_id) ALL NODES;

CREATE TABLE bitmap_demo.event_log (
    tenant_id INT NOT NULL, event_id INT NOT NULL, user_id INT NOT NULL,
    event_ts TIMESTAMP NOT NULL, channel VARCHAR(16) NOT NULL)
ORDER BY tenant_id, channel, event_ts, user_id
SEGMENTED BY HASH(user_id) ALL NODES;

CREATE TABLE bitmap_demo.device_state (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, device_id INT NOT NULL,
    online BOOLEAN, zone VARCHAR(16), temp_tenths INT, changes_10m INT,
    observed_at TIMESTAMP NOT NULL)
ORDER BY tenant_id, snapshot_id, device_id
SEGMENTED BY HASH(device_id) ALL NODES;

CREATE TABLE bitmap_demo.asset_state (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, asset_id INT NOT NULL,
    contains_pii BOOLEAN, deleted BOOLEAN, refreshed_at TIMESTAMP)
ORDER BY tenant_id, snapshot_id, asset_id
SEGMENTED BY HASH(asset_id) ALL NODES;

CREATE TABLE bitmap_demo.asset_source (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, asset_id INT NOT NULL,
    source VARCHAR(40) NOT NULL)
ORDER BY tenant_id, snapshot_id, source, asset_id
SEGMENTED BY HASH(asset_id) ALL NODES;

-- ---- index tables ----------------------------------------------------------------------------
-- Segmented by the chunk so that every operation on one chunk stays on one node. Payloads are
-- already compressed sets: ZSTD_FAST_COMP writes them faster than the default encoding (the daily
-- sets 2.6 times, the index with its two projections 1.3 times), no larger, and queries read them
-- at the same speed (measured on two copies of the index: bench/chains/run_chain20.sh).

CREATE TABLE bitmap_demo.bitmap_membership (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL,
    domain VARCHAR(16) NOT NULL, predicate VARCHAR(80) NOT NULL,
    chunk_id INT NOT NULL, local_id INT NOT NULL)
ORDER BY tenant_id, snapshot_id, domain, predicate, chunk_id, local_id
SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES;

CREATE TABLE bitmap_demo.bitmap_index (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL,
    domain VARCHAR(16) NOT NULL, predicate VARCHAR(80) NOT NULL,
    chunk_id INT NOT NULL, payload VARBINARY(16384) NOT NULL ENCODING ZSTD_FAST_COMP)
ORDER BY tenant_id, snapshot_id, domain, predicate, chunk_id
SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES;

CREATE TABLE bitmap_demo.daily_bitmap (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, day DATE NOT NULL,
    channel VARCHAR(16) NOT NULL, domain VARCHAR(16) NOT NULL,
    chunk_id INT NOT NULL, payload VARBINARY(16384) NOT NULL ENCODING ZSTD_FAST_COMP)
ORDER BY tenant_id, snapshot_id, domain, channel, day, chunk_id
SEGMENTED BY HASH(tenant_id, domain, chunk_id) ALL NODES;

-- ---- catalog and manifest --------------------------------------------------------------------

-- One row per predicate family. The definition is a query returning (predicate, entity_id) for
-- every predicate of the family; the builder replaces ${tenant}, ${snapshot} (the source snapshot)
-- and ${watermark} (the snapshot's source watermark, a TIMESTAMP). name_pattern is a regular
-- expression (REGEXP_LIKE) that matches every predicate name the family can produce and no name
-- of another family of the domain. A family is built and certified as a whole: a name of a
-- certified family with no row in a chunk is the empty set there, and a name that matches no
-- family is an error, never an empty set.
CREATE TABLE bitmap_demo.bitmap_family (
    tenant_id INT NOT NULL, domain VARCHAR(16) NOT NULL, family VARCHAR(40) NOT NULL,
    name_pattern VARCHAR(400) NOT NULL,
    definition VARCHAR(4000) NOT NULL)
ORDER BY tenant_id, domain, family
UNSEGMENTED ALL NODES;

-- Every predicate built for a snapshot, written by the builder: its family and its size.
CREATE TABLE bitmap_demo.bitmap_predicate (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, domain VARCHAR(16) NOT NULL,
    family VARCHAR(40) NOT NULL, predicate VARCHAR(80) NOT NULL,
    chunks INT NOT NULL, cardinality INT NOT NULL, bytes INT NOT NULL)
ORDER BY tenant_id, snapshot_id, domain, predicate
UNSEGMENTED ALL NODES;

-- Snapshot manifest, one row per (tenant, domain, snapshot); written by scripts/snapshot.sh only.
--   building   rows are being written or failed validation (note says why); never readable
--   verified   validated against the source; ready to publish
--   active     the published snapshot (at most one per tenant and domain)
--   retired    published before, kept readable for pinned readers until purged
-- A snapshot holds every set of the domain: bitmap_index rows and, when families lists "daily",
-- daily_bitmap rows. Its content is a function of source snapshot source_snapshot_id, the
-- events before source_watermark, and the change batches up to batch_id.
CREATE TABLE bitmap_demo.bitmap_snapshot (
    tenant_id INT NOT NULL, domain VARCHAR(16) NOT NULL, snapshot_id INT NOT NULL,
    source_snapshot_id INT NOT NULL,
    source_watermark TIMESTAMP NOT NULL,
    batch_id INT NOT NULL,               -- last change batch reflected (0: none)
    base_snapshot_id INT,                -- incremental build: the snapshot it was derived from
    chunk_bits INT NOT NULL,
    state VARCHAR(12) NOT NULL,          -- building | verified | active | retired
    families VARCHAR(2000) NOT NULL,     -- families certified complete, comma-separated
    built_at TIMESTAMP, verified_at TIMESTAMP, published_at TIMESTAMP, retired_at TIMESTAMP,
    note VARCHAR(2000))
ORDER BY tenant_id, domain, snapshot_id
UNSEGMENTED ALL NODES;

-- Ordered membership changes, written by the source pipeline; applied by scripts/snapshot.sh apply
-- one batch at a time, in batch order. Within a batch the row with the highest seq wins for each
-- (predicate, entity_id):
--   add     entity_id joins predicate
--   remove  entity_id leaves predicate
--   touch   the source rows of entity_id changed: its chunk is rebuilt from the source for every
--           family of the domain and the daily sets (predicate is NULL)
CREATE TABLE bitmap_demo.bitmap_change (
    tenant_id INT NOT NULL, domain VARCHAR(16) NOT NULL, batch_id INT NOT NULL, seq INT NOT NULL,
    op VARCHAR(8) NOT NULL, predicate VARCHAR(80), entity_id INT NOT NULL)
ORDER BY tenant_id, domain, batch_id, seq
SEGMENTED BY HASH(entity_id) ALL NODES;

-- Which database user may read which tenant through the views below.
CREATE TABLE bitmap_demo.bitmap_reader (
    user_name VARCHAR(128) NOT NULL, tenant_id INT NOT NULL)
ORDER BY user_name, tenant_id
UNSEGMENTED ALL NODES;

-- ---- reader views ----------------------------------------------------------------------------
-- Query roles get these views only (sql/access.sql), never the tables. Each view shows published
-- snapshots (active and retired) of the tenants mapped to CURRENT_USER() in bitmap_reader. A
-- reader pins one snapshot: it takes snapshot_id from v_bitmap_snapshot (state = 'active') once
-- and uses it in every statement; a retired snapshot stays readable until it is purged.

CREATE VIEW bitmap_demo.v_bitmap_snapshot AS
SELECT tenant_id, domain, snapshot_id, source_watermark, batch_id, chunk_bits, state, families,
       published_at, retired_at
FROM bitmap_demo.bitmap_snapshot
WHERE state IN ('active', 'retired')
  AND tenant_id IN (SELECT tenant_id FROM bitmap_demo.bitmap_reader WHERE user_name = CURRENT_USER());

CREATE VIEW bitmap_demo.v_bitmap_index AS
SELECT i.tenant_id, i.snapshot_id, i.domain, i.predicate, i.chunk_id, i.payload
FROM bitmap_demo.bitmap_index i
WHERE EXISTS (SELECT 1 FROM bitmap_demo.bitmap_snapshot m
              WHERE m.tenant_id = i.tenant_id AND m.domain = i.domain AND m.snapshot_id = i.snapshot_id
                AND m.state IN ('active', 'retired'))
  AND i.tenant_id IN (SELECT tenant_id FROM bitmap_demo.bitmap_reader WHERE user_name = CURRENT_USER());

CREATE VIEW bitmap_demo.v_daily_bitmap AS
SELECT d.tenant_id, d.snapshot_id, d.day, d.channel, d.domain, d.chunk_id, d.payload
FROM bitmap_demo.daily_bitmap d
WHERE EXISTS (SELECT 1 FROM bitmap_demo.bitmap_snapshot m
              WHERE m.tenant_id = d.tenant_id AND m.domain = d.domain AND m.snapshot_id = d.snapshot_id
                AND m.state IN ('active', 'retired'))
  AND d.tenant_id IN (SELECT tenant_id FROM bitmap_demo.bitmap_reader WHERE user_name = CURRENT_USER());

CREATE VIEW bitmap_demo.v_bitmap_predicate AS
SELECT p.tenant_id, p.snapshot_id, p.domain, p.family, p.predicate, p.chunks, p.cardinality, p.bytes
FROM bitmap_demo.bitmap_predicate p
WHERE EXISTS (SELECT 1 FROM bitmap_demo.bitmap_snapshot m
              WHERE m.tenant_id = p.tenant_id AND m.domain = p.domain AND m.snapshot_id = p.snapshot_id
                AND m.state IN ('active', 'retired'))
  AND p.tenant_id IN (SELECT tenant_id FROM bitmap_demo.bitmap_reader WHERE user_name = CURRENT_USER());

-- Family names and name patterns, without the definitions (they name the source tables).
CREATE VIEW bitmap_demo.v_bitmap_family AS
SELECT tenant_id, domain, family, name_pattern
FROM bitmap_demo.bitmap_family
WHERE tenant_id IN (SELECT tenant_id FROM bitmap_demo.bitmap_reader WHERE user_name = CURRENT_USER());

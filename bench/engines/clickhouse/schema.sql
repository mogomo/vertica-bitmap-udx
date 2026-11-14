-- ClickHouse tables for the cross-engine comparison (plan section 17, D13).
-- Source tables: the same rows as Vertica's bitmap_demo tables (bench/ch.sh export / load), same
-- columns; IDs as UInt32 (the generated IDs are dense, below 2^32), the type ClickHouse's bitmaps
-- are fastest with. Sort keys chosen for the queries (ClickHouse's equivalent of tuned projections).
-- Bitmap tables: one roaring bitmap per predicate (groupBitmap state), built by build_bitmaps.sql
-- from the same family definitions as sql/families.sql and the daily sets of scripts/build_index.sh.

CREATE DATABASE IF NOT EXISTS xbench;

CREATE TABLE xbench.user_profile (
    tenant_id UInt32, snapshot_id UInt32, entity_id UInt32,
    country LowCardinality(Nullable(String)), age Nullable(Int32),
    consent Nullable(Bool), suspended Nullable(Bool))
ENGINE = MergeTree ORDER BY (tenant_id, snapshot_id, country, entity_id)
SETTINGS allow_nullable_key = 1;

CREATE TABLE xbench.user_interest (
    tenant_id UInt32, snapshot_id UInt32, entity_id UInt32, topic LowCardinality(String))
ENGINE = MergeTree ORDER BY (tenant_id, snapshot_id, topic, entity_id);

CREATE TABLE xbench.event_log (
    tenant_id UInt32, event_id UInt64, user_id UInt32, event_ts DateTime('UTC'),
    channel LowCardinality(String))
ENGINE = MergeTree ORDER BY (tenant_id, channel, event_ts, user_id);

CREATE TABLE xbench.device_state (
    tenant_id UInt32, snapshot_id UInt32, device_id UInt32,
    online Nullable(Bool), zone LowCardinality(Nullable(String)),
    temp_tenths Nullable(Int32), changes_10m Nullable(Int32), observed_at DateTime('UTC'))
ENGINE = MergeTree ORDER BY (tenant_id, snapshot_id, device_id);

CREATE TABLE xbench.person_bitmap (
    tenant_id UInt32, snapshot_id UInt32, predicate LowCardinality(String),
    bm AggregateFunction(groupBitmap, UInt32))
ENGINE = MergeTree ORDER BY (tenant_id, snapshot_id, predicate);

CREATE TABLE xbench.daily_bitmap (
    tenant_id UInt32, snapshot_id UInt32, day Date, channel LowCardinality(String),
    bm AggregateFunction(groupBitmap, UInt32))
ENGINE = MergeTree ORDER BY (tenant_id, snapshot_id, channel, day);

CREATE TABLE xbench.device_bitmap (
    tenant_id UInt32, snapshot_id UInt32, predicate LowCardinality(String),
    bm AggregateFunction(groupBitmap, UInt32))
ENGINE = MergeTree ORDER BY (tenant_id, snapshot_id, predicate);

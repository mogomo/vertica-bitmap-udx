-- Schema bitmap_live: a bitmap index that Vertica maintains by itself.
--
-- A live aggregate projection may call C++ transform functions (manual, "Pre-aggregating UDTF
-- results"): a pre-pass function turns the rows of every load into partial results, a batch function
-- merges partial results when storage containers are merged and when the projection is read. With
-- vbitmap.bm_build as the pre-pass and vbitmap.bm_union as the batch function the projection holds
-- one Roaring set per (tenant, snapshot, domain, chunk, predicate): the same rows as
-- bitmap_demo.bitmap_index, kept up to date by every INSERT or COPY into the anchor table, inside
-- the transaction of the load. No build job, no refresh job; the expression functions read the
-- projection by its name.
--
-- Scope: the anchor table of such a projection is append-only (no UPDATE, DELETE or MERGE), so it
-- suits facts that are only ever added (tags, interests, events). The projection is segmented by
-- its PARTITION BY columns. Reading a set that was loaded in several pieces merges the pieces at
-- query time until the Tuple Mover has merged the containers.
--
-- vsql variable: with_projections (1: create the live projections now; 0: tables only, for loading
-- first and building the projections from the stored rows with scripts/live_index.sh projections).

CREATE SCHEMA bitmap_live;

-- One row per (entity, predicate): "this person has this tag". The source of the person sets.
-- chunk_id is filled by its DEFAULT, so a load names the other five columns only. Keep it a column
-- of the table: the live projection then partitions by table columns only, which is the form that
-- can be built from stored rows and maintained by every kind of load.
CREATE TABLE bitmap_live.tag (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, domain VARCHAR(16) NOT NULL,
    predicate VARCHAR(80) NOT NULL, entity_id INT NOT NULL,
    chunk_id INT NOT NULL DEFAULT (entity_id >> 16))
ORDER BY tenant_id, snapshot_id, domain, predicate, entity_id
SEGMENTED BY HASH(entity_id) ALL NODES;

-- Events, for the sets of distinct users per day and channel; day and chunk_id by DEFAULT.
CREATE TABLE bitmap_live.event (
    tenant_id INT NOT NULL, user_id INT NOT NULL, event_ts TIMESTAMP NOT NULL,
    channel VARCHAR(16) NOT NULL,
    day DATE NOT NULL DEFAULT (event_ts::DATE), chunk_id INT NOT NULL DEFAULT (user_id >> 16))
ORDER BY tenant_id, channel, event_ts, user_id
SEGMENTED BY HASH(user_id) ALL NODES;

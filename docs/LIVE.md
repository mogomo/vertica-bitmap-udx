# Live index: sets that Vertica maintains by itself

The snapshot lifecycle ([LIFECYCLE.md](LIFECYCLE.md)) builds an index, checks it against its source
and publishes it. For facts that are only ever added (tags, interests, events) there is a second
form that needs no build job at all: a **live aggregate projection** that calls the library's own
functions. Vertica then updates the sets with every `INSERT` or `COPY`, inside the transaction of
the load, and a reader can never see a table and its sets disagree.

Script: `scripts/live_index.sh`. SQL: `sql/live.sql`, `sql/live_projections.sql`. Tests:
`tests/sql/test_live.sh`. Measurements: the article (`blog/BLOG.md`, "Test four: fresh data, and the index that maintains itself").

## The mechanism

Vertica's live aggregate projections may call C++ transform functions (manual: "Pre-aggregating
UDTF results"). The projection names two of them:

- a **pre-pass** function, run on the rows of each load: `vbitmap.bm_build` turns the local IDs of a
  (chunk, predicate) into one Roaring payload;
- a **batch** function, run when storage containers are merged and when the projection is read:
  `vbitmap.bm_union` merges the payloads of a (chunk, predicate) into one.

```sql
CREATE TABLE bitmap_live.tag (
    tenant_id INT NOT NULL, snapshot_id INT NOT NULL, domain VARCHAR(16) NOT NULL,
    predicate VARCHAR(80) NOT NULL, entity_id INT NOT NULL,
    chunk_id INT NOT NULL DEFAULT (entity_id >> 16));

CREATE PROJECTION bitmap_live.bitmap_index (tenant_id, snapshot_id, domain, chunk_id, predicate, payload) AS
SELECT tenant_id, snapshot_id, domain, chunk_id, predicate,
       vbitmap.bm_union(sq.part) OVER (PARTITION BATCH BY tenant_id, snapshot_id, domain, chunk_id, predicate) AS (payload)
FROM (SELECT tenant_id, snapshot_id, domain, chunk_id, predicate,
             vbitmap.bm_build(entity_id & 65535)
               OVER (PARTITION PREPASS BY tenant_id, snapshot_id, domain, chunk_id, predicate) AS (part)
      FROM bitmap_live.tag) sq;
```

The chunk is a column with a DEFAULT, not an expression in the projection: loads name the other
columns and never see it, and the projection's `PARTITION BY` lists contain table columns only.
Keep it that way in your own tables: it is the form that can be built from stored rows and
maintained by every kind of load.

The projection has the columns of `bitmap_demo.bitmap_index` and is read by its name with the
same functions:

```sql
INSERT INTO bitmap_live.tag (tenant_id, snapshot_id, domain, predicate, entity_id)
  VALUES (1, 1, 'person', 'topic_chess', 70000);
COMMIT;                                   -- the set topic_chess now contains 70000

SELECT SUM(cnt) FROM (
  SELECT vbitmap.bm_count(chunk_id, predicate, payload USING PARAMETERS expr = 'topic_sports - topic_chess')
         OVER (PARTITION BY chunk_id)
  FROM bitmap_live.bitmap_index
  WHERE tenant_id = 1 AND snapshot_id = 1 AND domain = 'person'
    AND predicate IN ('topic_sports', 'topic_chess')) t;
```

`bitmap_live.daily_bitmap` does the same for events: one set of users per (tenant, channel, day,
chunk), kept current as events arrive, so "distinct users per day" and "distinct users over any
range of days" are always exact and always fresh.

## Using it

```bash
scripts/live_index.sh create                 # schema bitmap_live, both tables, both live projections
scripts/live_index.sh load --tenant=N        # tag rows from the predicate catalog, events of the tenant
scripts/live_index.sh status                 # containers, rows and bytes per projection
scripts/live_index.sh drop
```

`create --tables-only`, `load`, then `projections` loads first and builds the projections from the
stored rows (how the benchmark measures the build). In your own schema only the `CREATE PROJECTION`
statement matters: any table with an ID column and the columns you want to group by will do.

## What to know

- **Append only.** A table with such a projection takes new rows only, no `UPDATE`, `DELETE` or
  `MERGE` (Vertica says so when the projection is created). Use it for facts that are
  added, and the snapshot lifecycle for attributes that change. Both forms can feed one expression:
  select the rows of both with `UNION ALL` under the expression function.
- **Unfenced is the natural mode.** When the projection is read, Vertica runs the batch function on
  every set the query touches. A set stored in one piece is passed through after its checksum is
  verified; a set loaded in several pieces is merged on the fly until the Tuple Mover has merged
  the containers. Fenced, every one of these sets crosses the process boundary twice.
- **Filters reach the storage.** Conditions on the `PARTITION BY` columns (tenant, predicate, day)
  are applied in the scan, before the batch function.
- **Order and segmentation follow the `PARTITION BY` list.** Put the chunk before the predicate so
  that the expression functions read the sets of a chunk together. On a cluster the sets of one
  chunk are spread over the nodes by the hash of the whole list.
- **No validation step, and none needed for consistency:** the sets are written by the same
  transaction as the rows. What the lifecycle adds on top (certified families, pinned snapshots,
  rollback to an earlier state) is not part of the live form.
- **Any 64-bit ID.** `entity_id >> 16` and `entity_id & 65535` map every INT, negative ones
  included, to a chunk and a local ID and back.
- **Loads name their columns.** `chunk_id` (and `day` in the event table) are filled by DEFAULT.
- **Replacing the library** (`make deploy`) prints `NOTICE 6932` for each function a projection
  depends on; the projection keeps working as long as the functions keep their behaviour. Drop
  schema `bitmap_live` before `make undeploy`.

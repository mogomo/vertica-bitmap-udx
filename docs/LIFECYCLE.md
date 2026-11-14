# Snapshot lifecycle

The bitmap index is derived data. Readers must never see a set that is half built, built from
the wrong source, or older than they think. The lifecycle makes this explicit: every set
belongs to an immutable **snapshot** of one (tenant, domain), a snapshot is checked against its
source before anyone can read it, and readers switch from one snapshot to the next in a single
transaction.

Script: `scripts/snapshot.sh`. Tests: `tests/sql/test_lifecycle.sh` (fixture) and
`tests/sql/test_scale.sh` (one million generated people).

## What a snapshot is

A row of `bitmap_demo.bitmap_snapshot` (the manifest) and the rows with the same
(tenant, domain, snapshot) in `bitmap_index`, `bitmap_predicate` and, for domain `person` with
daily sets, `daily_bitmap`. Its content is a function of three inputs, all recorded in the
manifest:

| Column | Meaning |
|---|---|
| `source_snapshot_id` | the source rows read (`${snapshot}` in the family definitions) |
| `source_watermark` | the time the snapshot describes: events before it, device observations at most 30 minutes older |
| `batch_id` | the last change batch reflected (0: none) |

`families` lists the predicate families built and certified complete (plus `daily`).
`base_snapshot_id` is set when the snapshot was derived incrementally from another one.

## States

```
             build / apply            validate ok             publish
  (none) ─────────────────► building ─────────────► verified ─────────► active
                              ▲  │                     │                 │ publish of another
                 retry (same  │  │ validation fails    │ validate fails  ▼ snapshot
                 command)     └──┘ ◄───────────────────┘              retired ──► purged
                                                                         │      (rows deleted)
                                                                         └─► active (rollback)
```

| State | Readable through the views | Can change |
|---|---|---|
| building | no | rebuilt by the same command (retry), or discarded |
| verified | no | published, discarded, or demoted to building by a failed validation |
| active | yes, at most one per (tenant, domain) | becomes retired when another snapshot is published |
| retired | yes, for readers that pinned it | published again (rollback) or purged |

A snapshot past `building` is never rebuilt: `build` refuses it. A failed build or apply leaves
the snapshot in `building` with the reason in `note`; readers keep reading the active snapshot.

## Commands

```bash
# full build of snapshot 1 from source snapshot 1, validated, then published
scripts/snapshot.sh build --tenant=1 --domain=person --snapshot=1 --watermark='2026-11-03 00:00:00' --daily --publish

# incremental: the active snapshot + change batch 1, source snapshot 3
scripts/snapshot.sh apply --tenant=1 --domain=person --batch=1 --source-snapshot=3 --publish

# the watermark moves (device state expires); no batch
scripts/snapshot.sh apply --tenant=1 --domain=device --source-snapshot=2 --watermark='2026-11-01 12:40:00' --publish

scripts/snapshot.sh validate --tenant=1 --domain=person --snapshot=4 --deep
scripts/snapshot.sh publish  --tenant=1 --domain=person --snapshot=4     # also: rollback to a retired one
scripts/snapshot.sh purge    --tenant=1 --domain=person --keep=1
scripts/snapshot.sh discard  --tenant=1 --domain=person --snapshot=5     # unpublished only
scripts/snapshot.sh status   --tenant=1
```

`--snapshot` defaults to the next free number, allocated under the manifest lock.

### Two builders

`build` writes the same payloads, byte for byte, in either of two ways:

- **The transform** (default): the family definitions are united and `bm_build ... OVER (PARTITION BY
  predicate, chunk)` makes one set per partition. It runs fenced or unfenced. Vertica sorts the
  membership rows for the partitions, and that sort is most of the build time.
- **The aggregate** (`--aggregate`): one `INSERT ... SELECT predicate, chunk, bm_build_agg(local_id)
  ... GROUP BY predicate, chunk` per SELECT of each family definition, all in one transaction.
  Vertica groups by hashing on every thread of the query; nothing is sorted. Vertica runs
  user-defined aggregates inside the server process only, so this builder needs the unfenced
  deployment. The state of a group is its raw bitset (8 KB): run the build in a resource pool whose
  per-query budget holds one bitset per (predicate, chunk), for example

  ```sql
  CREATE RESOURCE POOL bitmap_build MEMORYSIZE '0%' MAXMEMORYSIZE '40G' PLANNEDCONCURRENCY 1;
  ```

  and `scripts/snapshot.sh build ... --aggregate --pool=bitmap_build`. With too small a budget the
  group-by spills to disk and the build takes several times longer; the result is the same.
  A definition written as several SELECTs joined by `UNION ALL` on a line of its own is built
  SELECT by SELECT. Each statement adds a storage container to the index; Vertica's Tuple Mover
  merges them in the background.

Statistics are refreshed for the key columns only, and the payload columns are stored with
`ZSTD_FAST_COMP` (`sql/schema.sql`): payloads are compressed sets already, and this encoding writes
them faster than the default at the same query speed. Measured on two copies of an index of 110 M
people that differ only in the encoding (`bench/encoding_copy.sh`, `bench/chains/run_chain20.sh`):
the index (9 GB in two projections) written in 53 s instead of 71 s, the daily sets in 6 s instead
of 16 s and a quarter smaller, query times equal at the median.

## Validation

`validate` runs at the end of every build and apply. A snapshot becomes `verified` only if all
checks pass:

1. Every family of the catalog was built, and no other.
2. One row per index key (tenant, snapshot, domain, predicate, chunk) and per daily key.
3. Every predicate name matches the name pattern of exactly one certified family.
4. The predicate list equals the index (family, chunks, cardinality, bytes).
5. Every payload header carries the snapshot's chunk width; every payload's checksum is read.
6. The cardinality of every (predicate, chunk) equals `COUNT(DISTINCT entity_id)` of the family
   definitions evaluated on the source snapshot at the watermark, in both directions (a missing
   or an extra chunk fails). The same for every (day, channel, chunk) of the daily sets against
   `event_log`.
7. With `--deep`, every set is also compared ID by ID with native SQL, in both directions.

Check 6 costs about as much as the native evaluation of every family; `--deep` expands every
set. Both are measured in M5.

**Touched-only validation** (`apply --validate=touched`) narrows check 6 to the parts the apply
changed: the chunks touched by the batch, the (predicate, chunk) pairs of its add and remove
changes, and the families and daily sets rebuilt in full. Every other row must equal the base
snapshot: same length and same 16-byte header, whose CRC-32C covers header and body (comparing
whole payloads cost more than the full validation), and the base was itself validated against its
source. What this does not
see is a source change that the batch does not report: the source then disagrees with the index
outside the checked parts and the snapshot still verifies. The test shows that case and shows the
full validation finding it. Use it where the change feed is trusted, and run a full validation
from time to time; `--deep` always validates in full.

## Incremental builds (`apply`)

`apply` derives a new snapshot from a base snapshot (default: the active one). It reads one change
batch from `bitmap_demo.bitmap_change`:

| op | Meaning | Applied as |
|---|---|---|
| `touch` | the source rows of `entity_id` changed | its chunk is rebuilt from the source for every family and the daily sets |
| `add` | `entity_id` joins `predicate` | (base ANDNOT removed) OR added, per (predicate, chunk) |
| `remove` | `entity_id` leaves `predicate` | same formula |

Rules:

- **Order inside a batch.** For each (predicate, entity) only the change with the highest `seq`
  counts, so add, remove, add leaves the entity in the set and add, remove leaves it out. Without
  this resolution the result depends on how adds and removes are combined (the test shows both
  wrong answers). `seq` must be unique in a batch.
- **Order of batches.** Batch B must follow the base's batch (B = base + 1). If the active
  snapshot already reflects B, `apply` does nothing (replay is idempotent). If an earlier run of
  the same apply left a verified snapshot, it is reused; a building one is retried in place.
- **Recomputation wins.** A change in a touched chunk, or in a family rebuilt in full, is ignored:
  that part comes from the source.
- **Rebuilt in full:** families whose definition uses `${watermark}` when the watermark moves
  (the device families: an observation older than 30 minutes leaves every set), the daily sets
  when the watermark moves, families added to the catalog since the base, and `--recompute=...`.
  Editing a family definition requires `--recompute=family` (the manifest records names, not
  definitions).
- **Everything else is copied** from the base.
- A name in an add or remove must match exactly one family pattern.

The source must reflect the batch: validation compares the result with the source snapshot,
so a batch that disagrees with the source is never published. The tests compare incremental
snapshots with full builds of the same state: equal byte for byte, on the fixture and on one
million people.

**Removing an event** does not remove the user from the daily set if another event of that day
and channel remains. The pipeline deletes the event and touches the user; the chunk's daily sets
are rebuilt from the remaining events.

## Readers

Query roles read views, never tables (`sql/access.sql`, role `bitmap_demo_query`):

| View | Content |
|---|---|
| `v_bitmap_snapshot` | published snapshots (active, retired) |
| `v_bitmap_index`, `v_daily_bitmap`, `v_bitmap_predicate` | rows of published snapshots |
| `v_bitmap_family` | family names and name patterns (no definitions) |

Each view shows only the tenants mapped to `CURRENT_USER()` in `bitmap_demo.bitmap_reader`.
Views run with their owner's privileges, so the reader needs no grant on the tables.

**Pinning.** A reader resolves the active snapshot once and uses its number in every statement.
A single statement can also resolve it inline; that is consistent because one statement reads
one snapshot of committed data (Vertica manual, READ COMMITTED isolation):

```sql
SELECT ... FROM bitmap_demo.v_bitmap_index
WHERE tenant_id = 1 AND domain = 'person'
  AND snapshot_id = (SELECT snapshot_id FROM bitmap_demo.v_bitmap_snapshot
                     WHERE tenant_id = 1 AND domain = 'person' AND state = 'active');
```

A publish does not disturb a pinned reader: the previous snapshot becomes `retired` and stays
readable until it is purged. `scripts/bmq` pins the active snapshot (or `--snapshot=N`) and,
after the query, checks that the snapshot still exists. Purge deletes the manifest row and the
data rows in one transaction, so a reader whose snapshot is gone gets an error, not a smaller
number.

**Complete and empty, or not built.** A name of a certified family with no payload is the empty
set. A name that matches no family, or whose family the snapshot does not certify, is an error in
`bmq`.

## Concurrency and limits

- Readers take no locks. `publish`, `purge`, `discard` and the start of `build`/`apply` lock the
  manifest table (`LOCK TABLE ... IN EXCLUSIVE MODE`) for a short transaction.
- One writer per (tenant, domain) at a time. Two builders of the same explicit snapshot number
  would overwrite each other's rows; the caller serializes them.
- Purge uses `DELETE`. Partitioning the index tables by snapshot (to drop whole partitions) is an
  M5 measurement.
- Function grants survive a redeploy (`CREATE OR REPLACE FUNCTION`, checked on 26.3) but not
  `make undeploy` (the library is dropped): run `sql/access.sql` again after a fresh install.
- Source snapshots are not managed here: removing old source rows is the pipeline's job.
- Chunk widths 8 to 16 bits. The index tables store payloads as VARBINARY(16384) (the largest
  16-bit payload is 8,208 bytes); an 18-bit chunk can reach 32 KB and would need VARBINARY(65000)
  columns, so `build` refuses `--chunk-bits` above 16. The functions themselves accept 18 bits
  (`scripts/build_index.sh` into tables of your own).

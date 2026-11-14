# Pinned sets: an audience as a row filter

Most uses of an audience stay inside set algebra: count it, break it down, save it. Sometimes the
members have to meet rows of another table: totals of a column nobody indexed, an export of IDs with
attributes, a filter on a fact table. The classic form is a semi-join with the ID list:

```sql
SELECT COUNT(*), COUNT(age), SUM(age) FROM bitmap_demo.user_profile x
WHERE x.tenant_id = 10 AND x.snapshot_id = 1
  AND x.entity_id IN (SELECT entity_id FROM (SELECT vbitmap.bm_ids(...) OVER (PARTITION BY chunk_id) FROM ...) t);
```

It produces every ID as a row and hashes it before the first profile row is tested. A pinned set
skips both. `bm_pin` evaluates the expression and keeps the result in memory as plain bitsets;
`bm_member` is a scalar function that tests an ID against it, so Vertica runs it as a filter of the
scan, on every thread that reads the table:

```sql
SELECT vbitmap.bm_pin(chunk_id, predicate, payload USING PARAMETERS
         expr = 'country_IL & topic_sports - topic_finance', name = 'aud') OVER ()
FROM (SELECT chunk_id, predicate, payload FROM bitmap_demo.bitmap_index
      WHERE tenant_id = 10 AND snapshot_id = 1 AND domain = 'person'
        AND predicate IN ('country_IL', 'topic_sports', 'topic_finance')
      UNION ALL SELECT NULL, NULL, NULL) r;          -- returns (members, chunks)

SELECT COUNT(*), COUNT(age), SUM(age) FROM bitmap_demo.user_profile x
WHERE x.tenant_id = 10 AND x.snapshot_id = 1
  AND vbitmap.bm_member(x.entity_id USING PARAMETERS name = 'aud');
```

The two statements can be sent as one message. The set serves any number of later statements of
the session, on any table that carries the ID.

## The functions

| Function | Result | |
|---|---|---|
| `bm_pin(chunk_id, predicate, payload USING PARAMETERS expr, name) OVER ()` | `(members, chunks)` | evaluates the expression over the index rows it is given (as `bm_count` does) and pins the result |
| `bm_pin(chunk_id, payload USING PARAMETERS name) OVER ()` | `(members, chunks)` | pins the union of payload rows: a saved set, the rows of `bm_eval`, the index rows of one predicate |
| `bm_member(entity_id USING PARAMETERS name)` | `BOOLEAN` | true if the ID is in the set; NULL for a NULL ID; false for a negative ID |
| `bm_unpin(name)` | `BOOLEAN` | drops the set; true if there was one |

`bm_pin` takes all its rows in one partition, so it is called `OVER ()`; a `PARTITION BY` clause is
an error. Names hold letters, digits and underscores (at most 64 characters) and are not case
sensitive.

## Rules

- **A set belongs to the session that pinned it.** `bm_pin` registers the set under a random token
  and leaves the token in a user-defined session parameter (`pin_<name>`, visible with `SHOW SESSION
  UDPARAMETER ALL`). Another session has no token and gets an error, also when it uses the same name.
  Pinning again under a name replaces the set.
- **A missing set is an error, never an empty set.** If the set is not in memory, `bm_member` stops
  the statement and says so.
- **Vertica does not call a transform function without input rows.** A `bm_pin` whose `FROM` clause
  returns nothing returns no row and pins nothing, and a set pinned under the name before stays in
  place. Append one row of NULLs to the input, as above: the function skips it, and an audience
  with no operand rows is pinned as the empty set.
- **Memory.** A pinned set is one bitset of 8 KB per chunk that has a member: 1.25 MB for any
  audience of 10 million people with dense IDs, 12.5 MB for 100 million. The sets of a process
  together may take 1 GiB; beyond that the least recently used ones are dropped, as are sets not
  used for 30 minutes (their next use is the error above: pin again). `bm_unpin` frees a set at once.
- **Where the set lives.** In the process that ran `bm_pin`: with the functions unfenced that is the
  Vertica process of the node the session is connected to, fenced it is the session's side process.
  On a database with several nodes the rows of a segmented table are filtered on every node, and
  the other nodes do not hold the set: `bm_member` reports it. Use the semi-join there.
- **Fenced or unfenced.** The filter is made for the unfenced deployment, where a row costs a few
  nanoseconds. Fenced, every row of the scanned table crosses to the side process, and the semi-join
  with the ID list is the faster form.

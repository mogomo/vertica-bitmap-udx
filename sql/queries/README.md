# Queries

Every challenge has a native SQL form (the correctness oracle), an explicit bitmap form (joins
of index rows on `chunk_id` with scalar functions) and, where it applies, an expression form (one
scan per chunk with `bm_count`, `bm_ids`, `bm_eval` or `bm_facets`, no joins). The files use
`${tenant}` and `${snapshot}` (`q4/native` also `${watermark}`, the device snapshot's watermark:
observations older than 30 minutes do not count); `scripts/run_query.sh NAME --tenant=1
--snapshot=1 [--watermark=TS]` fills them in, runs the query and sorts the rows. These files read
the tables directly (any snapshot, published or not); readers use the views of
docs/LIFECYCLE.md. `tests/sql/test_fixture.sh` checks every answer below on both
paths and compares the native and bitmap rows as sets in both directions.

| Query | Native | Bitmap | Fixture answer (tenant 1, snapshot 1) |
|---|---|---|---|
| Q1 audience: IL, age 25 to 54, consent, not suspended, sports or finance | `q1/native_ids`, `q1/native_count` | `q1/bitmap_ids`, `q1/bitmap_count`, `q1/expr_ids`, `q1/expr_count` | IDs 1, 65536, 4294967296; count 3 |
| Q2 exact distinct web users, 2026-11-01 and 2026-11-02 | `q2/native`, `q2/native_daily` | `q2/bitmap`, `q2/bitmap_daily` | 3 over both days; 2 and 2 per day (the sum of daily counts, 4, is wrong) |
| Q2b distinct users of web and app, same days, from the same stored sets | `q2b/native` | `q2b/bitmap` | 4 (IDs 1, 3, 65536, 4294967296) |
| Q3 users per topic inside the Q1 audience | `q3/native` | `q3/bitmap`, `q3/expr` | topic_finance 1, topic_sports 2 |
| Q3 disjunctive: per topic, the audience without its topic filter | `q3/native_disjunctive` | `q3/expr_disjunctive` | topic_finance 1, topic_sports 2 (the fixture has no other topics) |
| Q4 devices: online, zone A, at least 80.0 C, more than 3 changes | `q4/native` | `q4/bitmap`, `q4/expr` | ID 10 |
| Q5 assets: PII, not deleted, from ERP_A, refreshed before 2026-10-25 | `q5/native` | `q5/bitmap`, `q5/expr` | ID 100 |
| Q6 retention grid: web users active on both days of every pair | `q6/native` | `q6/bitmap` | 11-01/11-01: 2, 11-01/11-02: 1 (50%), 11-02/11-02: 2 |
| Q7 overlap ranking: Jaccard index of sports with every other topic | `q7/native` | `q7/bitmap` | topic_finance: 1 / 7 = 0.1429 |
| Q8 IL users interested in sports and not in finance | `q8/native` | `q8/bitmap`, `q8/expr` | IDs 1, 2, 7, 4294967296 |
| Q8 NULL trap: "not suspended" as a complement against `suspended IS FALSE` | `q8/native_trap` | `q8/bitmap_trap`, `q8/expr_trap` | 6 and 6; with a person of unknown suspension (test snapshot 9): 7 and 6 |
| Q9 attribute totals of the Q8 audience: people, people with a known age, sum of ages | `q9/native` | `q9/bitsliced` (needs the family of `sql/families_bitsliced.sql`) | 4, 3, 146 on snapshot 1; `tests/sql/test_bitsliced.sh` checks 7, 6, 491 on its own snapshot 8 |

Tenant 2 holds the same IDs 1, 2, 3 with other attributes: Q1 gives IDs 2, 3 and Q8 gives ID 2.

## Expressions and scripts/bmq

`scripts/bmq 'EXPR'` runs an expression over the active snapshot (or `--snapshot=N`) through the
reader views and derives the `predicate IN (...)` list from it;
`--mode=ids|facets|native-ids|native-count` select the output. A name of a family certified in the
snapshot but without payload is the empty set; a name that matches no family, or a family that the
snapshot does not certify, is an error. `--raw --snapshot=N` reads the tables (an unpublished
snapshot, for administrators). Syntax: names, `&` (and), `-` (and not), `^` (xor), `|` (or), in
this order of precedence, and parentheses; there is no unary NOT.

## Writing explicit bitmap SQL

- Restrict tenant, snapshot and domain first, then join the predicate rows on `chunk_id`.
- A required operand (AND) is an inner join: a chunk without a row for it is empty there.
- An optional operand (OR, the right side of ANDNOT) is a left join with
  `COALESCE(payload, vbitmap.bm_empty())`. This is correct only for a predicate of a family that
  the snapshot certifies (`families` in the manifest).
- Sum cardinalities across chunks only after every operation inside the chunk: chunks are
  disjoint, so the sum is exact.
- Unite time buckets inside each chunk (`bm_union ... OVER (PARTITION BY ..., chunk_id)`)
  before counting.

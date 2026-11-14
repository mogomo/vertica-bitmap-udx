# Measurement chains

To measure the article's results on your own machine use `bench/reproduce.sh`: one script, any
tenant, any folder. This folder is the record of how the published numbers were made.

The exact command sequences that produced the published measurements, kept as they ran (paths
relative to the workstation's home folder: the repository in `~/vertica-bitmap-udx`, the run records
in `~/bitmap_record`). Every step runs through `bench/record.sh`, which writes one run folder (raw
timings, answers, plans, settings, versions, cgroup samples, console) and an index row. Each chain
starts when the previous one wrote `ALL_DONE` to its log. One engine runs at a time, and nothing else
runs on the machine during a measured step.

Order and content (dataset: `scripts/generate.sh --default`, tenant 10, unless noted):

| Chain | Runs |
|---|---|
| (by hand) | generation of tenant 10 (`generate-default-t10`) |
| `run_builds_t10.sh` | lifecycle builds of the person, device and asset indexes; storage |
| `run_latency_t10.sh` | latency floor; latency of every path at 1 client, then 8 and 32 clients |
| `run_after_t10.sh` | long floor; per-family build; hand-tuned native projection; native latency again |
| `run_chain3_t10.sh` | purge; selectivity/operand sweep; unfenced deploy and latency; fenced again |
| `run_dbd_t10.sh` | Database Designer: copy schema, comprehensive design, latency at 1 / 8 / 32 clients |
| `run_chain7.sh` | 18 chunk bits (fails by design: 16 KB payload columns); ID-order, 64-bit ID and uniform-topic variants; test suite; tenant 10 regenerated; refresh 0.1 / 1 / 10 % |
| `run_chain8.sh` | reference answers; export; ClickHouse load, build, answer check, latency, refresh under load; Vertica refresh under load; 100 M people (`--large`, tenant 20) |
| `run_chain8b.sh` | the rest of chain 8 (its 100 M latency run was interrupted and is kept as invalid): latency at 100 M with q7.Bj, the overlap query written with plain subqueries, native at 100 M, storage |
| `run_chain9.sh` | refresh again after the touched-only validation fix |
| `run_chain10.sh` | chunk-ordered index projection and the facet form of Q7, fenced and unfenced, 10 M and 100 M (at 100 M: 1 client for the six queries, 32 clients for the audience count; answers checked against chain 8b's oracle answers) |
| `run_chain11.sh` | refresh under load again; ClickHouse latency rerun (driver fix) and refresh under load |
| `run_chain12.sh` | Q2 daily and Q4 again with the chunk-ordered projection in place, fenced and unfenced |
| `run_chain13.sh` | ClickHouse refresh under load again: the earlier runs rebuilt only the daily sets (`ch.sh build` looked for source rows of the new snapshot number); `ch.sh` now takes `--source-snapshot` and fails on an empty result |
| `run_chain14.sh` | the ID-list tests on equal terms (`driver.py --client=socket`: both engines read as raw bytes): rows and text blocks (`bm_ids_text`) delivered, the list used inside the engine, joined to the profiles, saved as a set and as a table, fenced and unfenced; the live index (`scripts/live_index.sh`): load, build, queries, 2 M tag rows appended under 32 clients; ClickHouse: the same ID tests and its own live form (materialized view into AggregatingMergeTree) with the same append |
| `run_chain14b.sh` | the live index with the projections created first and the load maintaining them (first table design; superseded by chain 15); ClickHouse's delivered ID lists again with its answers kept raw until the measured block ends, as Vertica's are |
| `run_chain14c.sh` | ClickHouse's SQL path for the delivered ID lists, read the same way |
| `run_chain15.sh` | everything Vertica again with the final library (AVX2 / POPCNT kernels chosen at load time), socket client: headline queries, ID-list tests, the live index in its second table design (chunk as a DEFAULT column): plain load, projections built from stored rows, load with the projections in place, queries, 2 M tag rows appended under 32 clients and idle |
| `run_chain16.sh` | facets and overlap in the one-pass form and in the every-thread form (`bm_pair_count OVER (PARTITION BEST)`), fenced and unfenced |
| `run_chain17.sh` | tuning experiment: the index stored in 16 containers (`bench/vertica_index_partitioned.sql`) against the index table, audience count and both facet forms, unfenced |
| `run_chain18.sh` | native ID lists read through the socket client on a fresh Database Designer copy (as `run_dbd_t10.sh`); the 100 M tenant again with the final library and the socket client, fenced and unfenced (six questions, every-thread forms, ID lists as text blocks; audience count and daily distinct users at 32 clients); the age stored as bit-sliced sets (`bench/bitsliced.sh add`) and the totals of an audience from set counts alone next to the join form, 10 M and 100 M; ClickHouse: the same sets (`ch.sh build-bits`) and the same two forms |
| `run_chain18b.sh` | the native device query at 100 M people (hand-tuned table) read through the socket client, like the bitmap list |
| `run_chain19.sh` | the three tests ClickHouse led, again: one row per ID with the ID formatted by the function (`bm_ids ... text = true`) next to the INT column; the audience joined to the profile rows through a pinned set (`bm_pin`, `bm_member`) next to the semi-join, 10 M at 1 and 32 clients in both modes and 100 M; the lifecycle build with the aggregate builder (`snapshot.sh build --aggregate --pool=bitmap_build`, `ZSTD_FAST_COMP` payload storage) at 10 M and 100 M, the new snapshot queried as written and then discarded; ClickHouse: its delivered lists, its join and its build once more |
| `run_chain19b.sh` | the build again: the aggregate builder fills its temporary table and the index receives one INSERT; person, daily and device snapshots of 10 M people built and validated; the new person snapshot queried as written and the published snapshot in the same run; the transform builder once more, fenced, with `ZSTD_FAST_COMP` payload storage and statistics on the key columns only; every snapshot built is discarded |
| `run_chain20.sh` | does the payload encoding change what a query costs: the headline queries, the Q8 list as rows and the Q8 audience joined to the profile rows on the benchmark tables as they are and on two copies that differ in the payload encoding only (`bench/encoding_copy.sh`: default and `ZSTD_FAST_COMP`); 10 M unfenced in two rounds (the second in reverse order), 10 M fenced and 100 M at 1 client on both copies |

From chain 10 on every statement is capped (`driver.py --statement-cap SECONDS`): a statement that
does not answer in time is recorded as a time-out error and the run continues, so one slow statement
costs the cap and not the night.

Before a chain: `bench/limits.sh start` (Vertica) or `bench/limits.sh start --engine=clickhouse`
(after `bench/limits.sh halt`); `bench/limits.sh status --check` must report `limits_ok=yes`.

Progress while a chain runs: `bash ~/bitmap_record/status.sh` (copy of `status.sh`), about 0.2 s on the
client CPUs. It judges progress from evidence of work done, not from CPU use, and from files only as
long as they show it: the queries checked, the executions measured and the console lines of the open
run; the statements finished and rows processed according to the request log that Vertica's Data
Collector writes by itself (`RequestsCompleted_*.log`); the lines that statement threads add to
`vertica.log`. Only when none of these changed for 6 minutes (one long statement, or a hang) does it
ask the engine, twice and 45 s apart, for the rows handled by the running statements: rows moved means
a long statement at work, frozen rows mean `state=STALL`. Each such probe is logged in
`~/bitmap_record/monitor.log`.
`watch.sh HOST` runs it every 3 minutes over ssh and ends on a stall, when the next run starts, when the
chains are done, or after 15 minutes for a routine look.

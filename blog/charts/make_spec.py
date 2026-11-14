#!/usr/bin/env python3
"""Writes charts.json, the specification that bench/charts.py turns into the article's charts.

  blog/charts/make_spec.py > blog/charts/charts.json

Only run names, query IDs and words are written here; every plotted value, every "times faster"
and every number in a chart title is read or computed by bench/charts.py from the recorded runs.

The contenders (one colour family per engine in every figure):
  v_sql      Vertica, plain SQL: the fastest of the hand-tuned and the Database Designer projections
  v_fenced   Vertica bitmap database, functions fenced (outside the server process)
  v_bitmap   Vertica bitmap database, functions unfenced (inside the server, as ClickHouse's are)
  ch_sql     ClickHouse, plain SQL
  ch_bitmap  ClickHouse bitmap functions (groupBitmap sets)
"""
import json

V = "vertica/"
C = "clickhouse/"
# ---- 10 M people (tenant 10)
NATIVE_1 = [V + "2026-11-12_latency-c1-t10", V + "2026-11-12_latency-native-tuned-c1-t10", V + "2026-11-12_dbd-latency-c1-t10"]
NATIVE_32 = [V + "2026-11-12_latency-c8c32-t10", V + "2026-11-12_latency-native-tuned-c8c32-t10", V + "2026-11-12_dbd-latency-c8c32-t10"]
NATIVE_IDS = [V + "2026-11-13_native-ids-socket-t10"]   # plain SQL ID lists (Q8, Q4), read like the bitmap lists
CH = C + "2026-11-13_latency-c1c32-t10"
# Final library, both engines read as raw bytes and decoded after the measured block
FENCED = V + "2026-11-13_final-headline-fenced-t10"
UNFENCED = V + "2026-11-13_final-headline-unfenced-t10"
PAR_FENCED = V + "2026-11-13_final-par-fenced-t10"       # facets and overlap on every thread (bm_pair_count)
PAR_UNFENCED = V + "2026-11-13_final-par-unfenced-t10"
IDS_FENCED = V + "2026-11-13_final-ids-rows-fenced-t10"
IDS_UNFENCED = V + "2026-11-13_final-ids-rows-unfenced-t10"
USE_FENCED = V + "2026-11-13_final-ids-use-fenced-t10"
USE_UNFENCED = V + "2026-11-13_final-ids-use-unfenced-t10"
SAVE_FENCED = V + "2026-11-13_final-ids-save-fenced-t10"
SAVE_UNFENCED = V + "2026-11-13_final-ids-save-unfenced-t10"
CH_IDS = C + "2026-11-13_ids-rows-raw-t10"
CH_IDS_SQL = C + "2026-11-13_ids-rows-sql-raw-t10"
CH_USE = C + "2026-11-13_ids-use-t10"
CH_SAVE = C + "2026-11-13_ids-save-t10"
# One row per ID and the audience as a row filter: Vertica unfenced sends the IDs as text rows
# (bm_ids text = true) and filters the profile rows through a pinned set (bm_pin, bm_member);
# fenced it sends INT rows and joins with the ID list. The two unfenced forms were measured three
# times on the benchmark tables; charts and article show the middle run ("pick": "median").
ROWS_UNFENCED = [V + "2026-11-13_rows-text-unfenced-t10",
                 V + "2026-11-13_encoding-rows-orig-unfenced-r1-t10",
                 V + "2026-11-13_encoding-rows-orig-unfenced-r2-t10"]
JOIN_FENCED = V + "2026-11-13_join-pin-fenced-t10"
JOIN_UNFENCED = [V + "2026-11-13_join-pin-unfenced-t10",
                 V + "2026-11-13_encoding-join-orig-unfenced-r1-t10",
                 V + "2026-11-14_encoding-join-orig-unfenced-r2-t10"]
CH_ROWS2 = C + "2026-11-13_ids-rows2-t10"
CH_JOIN2 = C + "2026-11-13_ids-join2-t10"
# Totals of an attribute over the audience from bit-sliced sets, no join
AGG_FENCED = V + "2026-11-13_final-agg-fenced-t10"
AGG_UNFENCED = V + "2026-11-13_final-agg-unfenced-t10"
CH_AGG = C + "2026-11-13_ids-agg-t10"
# Keeping the sets: builds and the live append under load
BUILD_PERSON = V + "2026-11-13_build-agg2-person-t10"
BUILD_DEVICE = V + "2026-11-13_build-agg2-device-t10"
CH_BUILD = C + "2026-11-13_build2-t10"
CH_BUILD_BITS = C + "2026-11-13_build-bits2-t10"
LIVE_APPEND = V + "2026-11-13_live2-append-under-load-unfenced-t10"
CH_LIVE_APPEND = C + "2026-11-13_live-append-under-load-t10"
# ---- 100 M people (tenant 20)
T20_NATIVE = V + "2026-11-13_latency-native-c1-t20"
T20_NATIVE_Q4 = V + "2026-11-13_native-q4-socket-t20"
T20_DEFAULT = V + "2026-11-13_latency-bitmap-c1c32-t20b"
T20_FENCED = V + "2026-11-13_final-headline-fenced-t20"
T20_UNFENCED = V + "2026-11-13_final-headline-unfenced-t20"
T20_PAR_FENCED = V + "2026-11-13_final-par-fenced-t20"
T20_PAR_UNFENCED = V + "2026-11-13_final-par-unfenced-t20"
T20_ROWS = V + "2026-11-13_rows-text-unfenced-t20"

VS_CH = ["Vertica", ["v_bitmap", "v_fenced"], "ClickHouse", ["ch_bitmap"]]          # verdict: engine against engine
VS_SQL = ["Bitmap", ["v_bitmap", "v_fenced"], "Plain SQL", ["v_sql"]]              # verdict: inside Vertica
SETUP = ("10 million people, 200 million interest rows; one machine, each engine limited to 20 CPUs and 56 GiB; "
         "median time of the recorded executions, shorter is faster; every answer checked against plain SQL")


def cells(runs, ids, clients):
    return [{"run": r, "query": q, "clients": clients} for r in runs for q in ids]


def one(run, query, clients):
    return {"from": cells([run], [query], clients)}


def fastest(runs, ids, clients):
    return {"pick": "min", "from": cells(runs, ids, clients)}


def middle(runs, query, clients):
    return {"pick": "median", "from": cells(runs, [query], clients)}


def bar(series, source):
    return dict(source, series=series)


# The six questions. Each entry gives the source of every path at a number of clients.
# Facets (Q3) and the overlap ranking (Q7) have two bitmap forms in Vertica, one pass per chunk
# (bm_facets) and every thread of the query (bm_pair_count); the faster one is shown.
def q_sources(clients):
    native = NATIVE_1 if clients == 1 else NATIVE_32
    return [
        ("How many people are in this audience? (5 filters, 2 topics)", {
            "v_sql": fastest(native, ["q1.count.A", "q1.count.D"], clients),
            "v_fenced": one(FENCED, "q1.count.Bplus", clients), "v_bitmap": one(UNFENCED, "q1.count.Bplus", clients),
            "ch_sql": one(CH, "q1.count.N", clients), "ch_bitmap": one(CH, "q1.count.C", clients)}),
        ("How many distinct web users on each of two days?", {
            "v_sql": fastest(native, ["q2.daily.A", "q2.daily.D"], clients),
            "v_fenced": one(FENCED, "q2.daily.B", clients), "v_bitmap": one(UNFENCED, "q2.daily.B", clients),
            "ch_sql": one(CH, "q2.daily.N", clients), "ch_bitmap": one(CH, "q2.daily.C", clients)}),
        ("Split the audience by all 500 topics", {
            "v_sql": fastest(native, ["q3.A", "q3.D"], clients),
            "v_fenced": {"pick": "min", "from": cells([FENCED], ["q3.Bplus"], clients) + cells([PAR_FENCED], ["q3.Bpar"], clients)},
            "v_bitmap": {"pick": "min", "from": cells([UNFENCED], ["q3.Bplus"], clients) + cells([PAR_UNFENCED], ["q3.Bpar"], clients)},
            "ch_sql": one(CH, "q3.N", clients), "ch_bitmap": one(CH, "q3.C", clients)}),
        ("Rank 499 topics by their overlap with sports", {
            "v_sql": fastest(native, ["q7.A", "q7.D", "q7.At", "q7.Dt"], clients),
            "v_fenced": {"pick": "min", "from": cells([FENCED], ["q7.Bplus"], clients) + cells([PAR_FENCED], ["q7.Bpar"], clients)},
            "v_bitmap": {"pick": "min", "from": cells([UNFENCED], ["q7.Bplus"], clients) + cells([PAR_UNFENCED], ["q7.Bpar"], clients)},
            "ch_sql": one(CH, "q7.N", clients), "ch_bitmap": one(CH, "q7.C", clients)}),
        ("Send the 530,315 IDs of an audience, one row per ID", {
            "v_sql": fastest(NATIVE_IDS, ["q8.A", "q8.D"], clients),
            "v_fenced": one(IDS_FENCED, "q8.Bplus", clients), "v_bitmap": middle(ROWS_UNFENCED, "q8.rowtext.Bplus", clients),
            "ch_sql": one(CH_IDS_SQL, "q8.N", clients), "ch_bitmap": one(CH_ROWS2, "q8.C", clients)}),
        ("List the 19,695 hot devices (4 filters)", {
            "v_sql": fastest(NATIVE_IDS, ["q4.A", "q4.D"], clients),
            "v_fenced": one(IDS_FENCED, "q4.Bplus", clients), "v_bitmap": one(IDS_UNFENCED, "q4.Bplus", clients),
            "ch_sql": one(CH_IDS_SQL, "q4.N", clients), "ch_bitmap": one(CH_IDS, "q4.C", clients)}),
    ]


def panels(clients, series, verdict):
    return [{"title": title, "verdict": verdict, "bars": [bar(s, src[s]) for s in series]}
            for title, src in q_sources(clients)]


Q1_1, Q1_32 = q_sources(1)[0][1], q_sources(32)[0][1]
LADDER = ["v_sql", "ch_sql", "ch_bitmap", "v_fenced", "v_bitmap"]
spec = {
    "_about": "Written by blog/charts/make_spec.py; values are read by bench/charts.py from the recorded runs.",
    "one_question": {
        "title": "One question, five ways to answer it: Vertica's bitmap database is first, {x0} times ahead of "
                 "ClickHouse's bitmap functions for one user and {x1} times with 32 users",
        "subtitle": "The question: how many consenting, active users in the country, aged 25 to 54, like sports or finance? " + SETUP,
        "panels": [
            {"title": "One user asks", "verdict": VS_CH, "bars": [bar(s, Q1_1[s]) for s in LADDER]},
            {"title": "32 users ask at once", "verdict": VS_CH, "bars": [bar(s, Q1_32[s]) for s in LADDER]},
        ],
    },
    "latency_1_client": {
        "title": "Inside Vertica, one user: the bitmap database answers the audience count {x0} times faster than tuned plain SQL",
        "subtitle": SETUP,
        "panels": panels(1, ["v_sql", "v_fenced", "v_bitmap"], VS_SQL),
    },
    "latency_32_clients": {
        "title": "Inside Vertica, 32 users at once: the bitmap database answers the audience count {x0} times faster than tuned plain SQL",
        "subtitle": SETUP,
        "panels": panels(32, ["v_sql", "v_fenced", "v_bitmap"], VS_SQL),
    },
    "engines_1_client": {
        "title": "Vertica against ClickHouse, one user: Vertica's bitmap database is faster on {a_wins} of {n} questions, "
                 "{x0} times on the audience count",
        "subtitle": "Same data, same machine, same limits, one engine running at a time, identical answers. " + SETUP,
        "panels": panels(1, ["v_bitmap", "v_fenced", "ch_bitmap"], VS_CH),
    },
    "engines_32_clients": {
        "title": "Vertica against ClickHouse, 32 users at once: Vertica's bitmap database answers the audience count {x0} times faster",
        "subtitle": "Same data, same machine, same limits, one engine running at a time, identical answers. " + SETUP,
        "panels": panels(32, ["v_bitmap", "v_fenced", "ch_bitmap"], VS_CH),
    },
}


# ---- ID lists: what happens to the 530,315 people of an audience
def three(title, vq, cq, vruns, crun, clients):
    return {"title": title, "verdict": VS_CH, "bars": [
        bar("v_bitmap", one(vruns[1], vq, clients)), bar("v_fenced", one(vruns[0], vq, clients)),
        bar("ch_bitmap", one(crun, cq, clients))]}


def id_lists(clients):
    out = [three("Use the list inside the database (count and sum of the IDs)", "q8.sum.Bplus", "q8.sum.C", (USE_FENCED, USE_UNFENCED), CH_USE, clients)]
    if clients == 1:
        out += [
            three("Save the audience as a set", "q8.save.set.Bplus", "q8.save.set.C", (SAVE_FENCED, SAVE_UNFENCED), CH_SAVE, 1),
            three("Save the audience as a table of IDs", "q8.save.ids.Bplus", "q8.save.ids.C", (SAVE_FENCED, SAVE_UNFENCED), CH_SAVE, 1),
        ]
    out += [
        {"title": "Send the list as text blocks (ClickHouse: its row stream)", "verdict": VS_CH, "bars": [
            bar("v_bitmap", one(IDS_UNFENCED, "q8.text.Bplus", clients)), bar("v_fenced", one(IDS_FENCED, "q8.text.Bplus", clients)),
            bar("ch_bitmap", one(CH_IDS, "q8.C", clients))]},
        {"title": "Send the list, one row per ID", "verdict": VS_CH, "bars": [
            bar("v_bitmap", middle(ROWS_UNFENCED, "q8.rowtext.Bplus", clients)), bar("v_fenced", one(IDS_FENCED, "q8.Bplus", clients)),
            bar("ch_bitmap", one(CH_ROWS2, "q8.C", clients))]},
        three("Size, known ages and sum of ages, from bit-sliced sets", "q8.agg.Bplus", "q8.agg.C", (AGG_FENCED, AGG_UNFENCED), CH_AGG, clients),
        {"title": "The same totals from 10 M profile rows, audience as a filter", "verdict": VS_CH, "bars": [
            bar("v_bitmap", middle(JOIN_UNFENCED, "q8.join.Bpin", clients)),
            dict(bar("v_fenced", one(JOIN_FENCED, "q8.join.Bplus", clients)), label="Vertica fenced (join with the list)"),
            bar("ch_bitmap", one(CH_JOIN2, "q8.join.C", clients))]},
    ]
    return out


IDS_SUB = ("An audience of 530,315 people out of 10 million. Both engines are read the same way: the clock stops when the "
           "last byte of the answer has arrived. Same machine and limits; median time, shorter is faster")
spec["id_lists_1_client"] = {
    "title": "The people behind the count, one user: Vertica's bitmap database is faster in all {n} uses of the list",
    "subtitle": IDS_SUB, "require": "a", "panels": id_lists(1)}
spec["id_lists_32_clients"] = {
    "title": "The people behind the count, 32 users at once: Vertica's bitmap database is faster in {a_wins} of {n} uses, level in {level}",
    "subtitle": IDS_SUB, "panels": id_lists(32)}


# ---- keeping the sets: build, live append under load
def line(run, regex, scale=1):
    return {"run": run, "line": regex, "scale": scale}


BUILD_V = {"pick": "sum", "from": [line(BUILD_PERSON, r"op=build .* build_s=([0-9.]+)"), line(BUILD_DEVICE, r"op=build .* build_s=([0-9.]+)")]}
BUILD_C = {"pick": "sum", "from": [line(CH_BUILD, r"op=build .* total_s=([0-9.]+)"), line(CH_BUILD_BITS, r"op=build-bits .* s=([0-9.]+)")]}
APPEND_V = {"from": [line(LIVE_APPEND, r"background: .* duration_s=([0-9.]+)")]}
APPEND_C = {"from": [line(CH_LIVE_APPEND, r"background: .* duration_s=([0-9.]+)")]}
LIVE = {"v_bitmap": "Vertica live index", "ch_bitmap": "ClickHouse live sets"}
spec["fresh_data"] = {
    "title": "Fresh data while 32 users query: Vertica's live index takes in 2 million rows in {v0.0} (ClickHouse: {v0.1}) "
             "and answers the audience count {x1} times faster meanwhile",
    "subtitle": "2 million new tag rows (1 % more data, every ID chunk) appended to sets that the engine maintains itself, during a "
                "mixed load of counts and facet breakdowns from 32 clients. No failed statement, no wrong answer, in either engine",
    "unit": "s",
    "labels": LIVE,
    "panels": [
        {"title": "Append 2 million rows; the sets are exact at commit", "verdict": VS_CH,
         "bars": [bar("v_bitmap", APPEND_V), bar("ch_bitmap", APPEND_C)]},
        {"title": "The audience count during that load (32 users)", "unit": "ms", "verdict": VS_CH,
         "bars": [bar("v_bitmap", one(LIVE_APPEND, "q1.count.Bplus", 32)), bar("ch_bitmap", one(CH_LIVE_APPEND, "q1.count.C", 32))]},
        {"title": "The 500-topic breakdown during that load (32 users)", "unit": "ms", "verdict": VS_CH,
         "bars": [bar("v_bitmap", one(LIVE_APPEND, "q3.Bplus", 32)), bar("ch_bitmap", one(CH_LIVE_APPEND, "q3.C", 32))]},
        {"title": "Build all 698 sets from the source tables", "verdict": VS_CH,
         "bars": [dict(bar("v_bitmap", BUILD_V), label="Vertica, aggregate builder"), dict(bar("ch_bitmap", BUILD_C), label="ClickHouse, groupBitmap")]},
    ],
}


# ---- 100 M people, one user, inside Vertica
def c(run, q):
    return {"run": run, "query": q, "clients": 1}


def t20(title, native, fenced, unfenced):
    return {"title": title, "verdict": VS_SQL, "bars": [
        {"series": "v_sql", "from": [native]}, dict(fenced, series="v_fenced"), dict(unfenced, series="v_bitmap")]}


def best(*cs):
    return {"pick": "min", "from": list(cs)}


spec["scale_100m"] = {
    "title": "Ten times the data, 100 million people: the audience count takes {v0.2} in Vertica's bitmap database and {v0.0} in plain SQL",
    "subtitle": "2 billion interest rows, 1 billion events, one user, one node; plain SQL on the hand-tuned projection "
                "(the overlap ranking: its single check execution); median time, shorter is faster",
    "panels": [
        t20("How many people are in this audience?", c(T20_NATIVE, "q1.count.A"), best(c(T20_FENCED, "q1.count.Bplus")), best(c(T20_UNFENCED, "q1.count.Bplus"))),
        t20("How many distinct web users on each of two days?", c(T20_NATIVE, "q2.daily.A"), best(c(T20_FENCED, "q2.daily.B")), best(c(T20_UNFENCED, "q2.daily.B"))),
        t20("Split the audience by all 500 topics", c(T20_NATIVE, "q3.A"),
            best(c(T20_FENCED, "q3.Bplus"), c(T20_PAR_FENCED, "q3.Bpar")), best(c(T20_UNFENCED, "q3.Bplus"), c(T20_PAR_UNFENCED, "q3.Bpar"))),
        t20("Rank 499 topics by their overlap with sports", {"run": T20_DEFAULT, "line": r"check: query=q7\.A .* ms=([0-9.]+)"},
            best(c(T20_FENCED, "q7.Bplus"), c(T20_PAR_FENCED, "q7.Bpar")), best(c(T20_UNFENCED, "q7.Bplus"), c(T20_PAR_UNFENCED, "q7.Bpar"))),
        t20("Send the 5,303,339 IDs of an audience, one row per ID", c(T20_NATIVE, "q8.A"), best(c(T20_FENCED, "q8.Bplus")), best(c(T20_ROWS, "q8.rowtext.Bplus"))),
        t20("List the 197,436 hot devices", c(T20_NATIVE_Q4, "q4.A"), best(c(T20_FENCED, "q4.Bplus")), best(c(T20_UNFENCED, "q4.Bplus"))),
    ],
}


# ---- refresh of a validated snapshot (Vertica only)
def step(run, name):
    return {"from": [{"run": V + run, "line": r"step=%s .* total_s=([0-9.]+)" % name}]}


def refresh_panel(title, run):
    return {"title": title, "verdict": ["Incremental", ["v_bitmap"], "Full rebuild", ["v_fenced"]], "bars": [
        dict(bar("v_fenced", step(run, "build_full")), label="Full rebuild"),
        dict(bar("v_bitmap", step(run, "apply_full")), label="Incremental refresh")]}


spec["refresh"] = {
    "title": "Vertica's validated snapshots: a change of 1 % of the people is applied in {v0.1} instead of a {v0.0} rebuild",
    "subtitle": "10 million people, 1 % changed; seconds, including the validation of every set against the source; the incremental "
                "result equals the full rebuild byte for byte",
    "unit": "s",
    "labels": {"v_fenced": "Vertica: full rebuild", "v_bitmap": "Vertica: incremental refresh"},
    "panels": [
        refresh_panel("Changes reported as add / remove (198,219 changes)", "2026-11-13_refresh-1pct-random-delta-fp-t10"),
        refresh_panel("Changes on recent sign-ups (2 of 153 ID chunks)", "2026-11-13_refresh-1pct-recent-mixed-fp-t10"),
        refresh_panel('"This person changed", spread over every chunk', "2026-11-13_refresh-1pct-random-mixed-fp-t10"),
    ],
}


# ---- the scoreboard: every head-to-head test, Vertica's bitmap database (unfenced) against
#      ClickHouse's bitmap functions
def row(label, a, b, unit="ms"):
    return {"label": label, "a": a, "b": b, "unit": unit}


def audience_rows(clients):
    q = {t: s for t, s in q_sources(clients)}
    rows = [row(t.split(" (")[0], s["v_bitmap"], s["ch_bitmap"]) for t, s in q_sources(clients)]
    rows[4:4] = []   # the list questions follow the four counting questions
    extra = [
        row("Use that list of IDs inside the database", one(USE_UNFENCED, "q8.sum.Bplus", clients), one(CH_USE, "q8.sum.C", clients)),
        row("Filter a 10 M-row table by the audience", middle(JOIN_UNFENCED, "q8.join.Bpin", clients), one(CH_JOIN2, "q8.join.C", clients)),
        row("Total an attribute over the audience (bit slices)", one(AGG_UNFENCED, "q8.agg.Bplus", clients), one(CH_AGG, "q8.agg.C", clients)),
    ]
    if clients == 1:
        extra.append(row("Save the audience as a set", one(SAVE_UNFENCED, "q8.save.set.Bplus", 1), one(CH_SAVE, "q8.save.set.C", 1)))
    return rows[:5] + extra + rows[5:]


spec["scoreboard"] = {
    "type": "scoreboard",
    "contenders": ["Vertica", "ClickHouse"],
    "colours": ["v_bitmap", "ch_bitmap"],
    "title": "The scoreboard: Vertica faster in {a_wins} of {n} tests, ClickHouse faster in {b_wins}, level in {level}",
    "subtitle": "Vertica's bitmap database against ClickHouse's bitmap functions, 10 million people, same machine and "
                "limits, identical answers, median times. The bar shows how many times faster the winner is",
    "groups": [
        {"title": "Audience questions, one user", "rows": audience_rows(1)},
        {"title": "Audience questions, 32 users at once", "rows": audience_rows(32)},
        {"title": "Keeping the sets fresh", "rows": [
            row("Append 2 M rows to live sets under 32 users", APPEND_V, APPEND_C, "s"),
            row("Audience count during that load", one(LIVE_APPEND, "q1.count.Bplus", 32), one(CH_LIVE_APPEND, "q1.count.C", 32)),
            row("500-topic breakdown during that load", one(LIVE_APPEND, "q3.Bplus", 32), one(CH_LIVE_APPEND, "q3.C", 32)),
            row("Build all 698 sets from the source tables", BUILD_V, BUILD_C, "s"),
        ]},
    ],
    "note": "A lead below 5 % counts as level. Vertica's bitmap functions run unfenced here, inside the server, as ClickHouse's "
            "built-in functions do; the fenced numbers are in the article's tables. Sources: sources.csv.",
}

print(json.dumps(spec, indent=1))

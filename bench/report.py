#!/usr/bin/env python3
"""Writes a Markdown report from recorded benchmark runs (folders written by bench/record.sh with
bench/driver.py output in driver/).

  bench/report.py RUN_DIR [RUN_DIR ...] [--title TEXT] [--out FILE]

For every answer group: one table with a row per path (query ID) and, per number of clients,
p50 / p95 / p99 latency in ms and throughput; the fastest path per number of clients; and a list
of the groups in which native SQL (paths .A, .At, .D and .Dt) is the fastest. Approximate paths are listed
but never counted as fastest. Each block (query and number of clients) is judged on its own: an
error or a wrong answer in it, or a run outside its limits or with a saturated client, marks it
invalid; other blocks of the same run stay. A block during which a client CPU averaged 90 % or more is marked
client-bound (its client latency measures the client; the engine time is in summary.csv).
Environment, limits and validity come from the run folders. Every
number is read from the files; nothing is typed in. Standard library only.
"""
import argparse
import csv
import os
import re
import sys
import time


def read_kv(path):
    out = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                for m in re.finditer(r"(\w+)=(\S+)", line):
                    out.setdefault(m.group(1), m.group(2))
    return out


def read_lines(path):
    return open(path).read().splitlines() if os.path.exists(path) else []


def client_busy(run_dir, start, end):
    """Mean busy percent of each client CPU over [start, end] from samples.csv (Unix time column)."""
    path = os.path.join(run_dir, "samples.csv")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        rd = list(csv.DictReader(f))
    if not rd or "unix_s" not in rd[0]:
        return None
    cols = [c for c in rd[0] if re.match(r"cpu\d+_busy_pct", c)]
    inside = [r for r in rd if start <= float(r["unix_s"]) <= end + 1.0]
    if not inside:
        return None
    return max(sum(float(r[c]) for r in inside) / len(inside) for c in cols)


# Paths in table order. Native SQL: A (as written), At (rewritten text), D and Dt (the same on the
# copy schema with the Database Designer's projections, bench/dbd.sh).
PATHS = ("A", "At", "D", "Dt", "B", "Bplus")
NATIVE = ("A", "At", "D", "Dt")


def path_of(qid):
    return qid.rsplit(".", 1)[1] if "." in qid else qid


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--title", default="Benchmark report")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    rows, runs, approx = [], [], set()
    for d in a.runs:
        d = d.rstrip("/")
        meta = read_kv(os.path.join(d, "meta.txt"))
        validity = next((l.split("=", 1)[1] for l in read_lines(os.path.join(d, "meta.txt"))
                         if l.startswith("validity=")), "unknown")
        runs.append((os.path.basename(d), meta, validity, d))
        wl = os.path.join(d, "driver", "workload.sql")
        for l in read_lines(wl):
            m = re.match(r"-- @query (\S+) .*approx=", l)
            if m:
                approx.add(m.group(1))
        s = os.path.join(d, "driver", "summary.csv")
        if not os.path.exists(s):
            continue
        with open(s) as f:
            for r in csv.DictReader(f):
                r["run"] = os.path.basename(d)
                r["client_busy"] = (client_busy(d, float(r["start_unix"]), float(r["end_unix"]))
                                    if r.get("start_unix") else None)
                # A block is judged on its own: its errors and mismatches (below), and the run's
                # limits and client CPU. A run made invalid by one failed block keeps its other blocks.
                r["valid"] = meta.get("limits_ok") == "yes" and meta.get("client_saturated") != "yes"
                rows.append(r)

    out = []
    w = out.append
    w(f"# {a.title}\n")
    w(f"Generated {time.strftime('%Y-%m-%d %H:%M')} by bench/report.py from {len(runs)} recorded runs. "
      "All numbers are read from the run folders.\n")
    w("## Runs\n")
    w("| Run | Duration (s) | Engine CPU (s) | Client CPUs busy (%) | Validity |")
    w("|---|---|---|---|---|")
    for name, meta, validity, d in runs:
        cc = " / ".join(v for k, v in sorted(meta.items()) if re.match(r"client_cpu\d+_busy_pct", k))
        w(f"| {name} | {meta.get('duration_s', '')} | {meta.get('engine_cpu_s', '')} | {cc} | {validity} |")
    w("")
    first = runs[0][3]
    env = read_lines(os.path.join(first, "environment.txt"))
    lim = read_lines(os.path.join(first, "limits_before.txt"))
    w("## Environment (first run)\n")
    w("```")
    for l in env:
        if not l.startswith("cpu0=") and not re.match(r"cpu\d+=", l):
            w(l)
    for l in lim:
        if l.startswith(("scope=", "cpuset", "pool_", "host_", "limits_ok", "vertica_version")):
            w(l)
    w("```\n")
    w("## Method\n")
    w("Each query first runs once in a correctness pass; its answer is compared with the native "
      "oracle of its answer group. Then, for each number of clients C, C sessions (one vsql process "
      "each, on the client CPUs) run warm-up executions, wait for one another, and run the measured "
      "executions; a session that has finished its share keeps running the query unmeasured until "
      "every session has finished, so the load stays at C. Latency is measured on the client from "
      "sending the statement to reading the end of its result. Percentiles interpolate linearly "
      "between ranks. Throughput counts the executions completed inside the measured window. Every "
      "measured answer is compared with the correctness pass. All runs here are warm (the data was "
      "read before); cold runs are reported separately when they exist.\n")

    groups = {}
    for r in rows:
        groups.setdefault(r["answer"], []).append(r)
    native_wins = []
    w("## Latency by answer group\n")
    for g in sorted(groups, key=lambda k: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", k)]):
        rs = groups[g]
        levels = sorted({int(r["clients"]) for r in rs})
        ids = sorted({r["query"] for r in rs}, key=lambda q: PATHS.index(path_of(q))
                     if path_of(q) in PATHS else 9)
        w(f"### {g}\n")
        head = "| Path | " + " | ".join(f"C={c}: p50 / p95 / p99 ms, q/s" for c in levels) + " |"
        w(head)
        w("|---|" + "---|" * len(levels))
        best = {}
        for q in ids:
            cells = []
            for c in levels:
                cand = [r for r in rs if r["query"] == q and int(r["clients"]) == c]
                if not cand:
                    cells.append("")
                    continue
                r = cand[-1]   # the latest run of this query and level
                flag = "" if r["valid"] and r["errors"] in ("0", "") and r["mismatches"] in ("0", "") else " (invalid)"
                if r["client_busy"] is not None and r["client_busy"] >= 90:
                    flag += " (client-bound: a client CPU at %.0f %%)" % r["client_busy"]
                cells.append(f"{float(r['p50_ms']):,.1f} / {float(r['p95_ms']):,.1f} / {float(r['p99_ms']):,.1f}, "
                             f"{float(r['throughput_qps']):,.2f}{flag}")
                if q not in approx and not flag:
                    if c not in best or float(r["p50_ms"]) < best[c][1]:
                        best[c] = (q, float(r["p50_ms"]))
            w(f"| {q}{' (approximate)' if q in approx else ''} | " + " | ".join(cells) + " |")
        w("")
        w("Fastest exact path (p50): " + "; ".join(f"C={c}: {best[c][0]}" for c in levels if c in best) + "\n")
        for c in levels:
            if c in best and path_of(best[c][0]) in NATIVE:
                native_wins.append((g, c, best[c][0]))
    w("## Where native SQL is the fastest\n")
    if native_wins:
        for g, c, q in native_wins:
            w(f"- {g} at {c} client(s): {q}")
    else:
        w("- none in these runs")
    w("")
    text = "\n".join(out)
    if a.out:
        with open(a.out, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()

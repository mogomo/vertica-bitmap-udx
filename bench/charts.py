#!/usr/bin/env python3
"""Charts for the blog and the video, generated from recorded runs only (no number typed by hand).

  bench/charts.py --spec blog/charts/charts.json --record ../benchmark_record --out blog/charts

Two kinds of chart, both side by side comparisons:

* A bar chart has panels, one per test (each with its own linear scale, so values from
  milliseconds to minutes stay readable without a log axis). A panel is titled with the question
  it stands for and has one bar per engine and path. A panel may carry a verdict: the fastest bar
  of one group against the fastest bar of another, shown at the right of the panel title
  ("Vertica 6.7x faster").
* A scoreboard has one row per test: the value of each of two contenders and a bar that points to
  the faster one, as long as its lead ("times faster"). Leads below 5 % are shown as "level". It
  also writes NAME.md, the same rows as a Markdown table for the article.

Where a value comes from: a bar (or a scoreboard side) names its source cells:
    {"series": "v_sql", "from": [{"run": "vertica/2026-11-12_latency-c1-t10", "query": "q1.count.A",
                                  "clients": 1}, ...], "pick": "min"}
"from" lists one or more (run, query, clients) cells of driver/summary.csv (p50_ms by default,
"metric" to change). "pick": "min" takes the fastest of them (plain SQL is the faster of the
hand-tuned and the Database Designer projections; a question with two bitmap forms shows the
faster form); "pick": "median" takes the middle one of an odd number of runs of the same test
(every cell must exist); "pick": "sum" adds them (a build made of several steps). A cell may
instead be {"run": ..., "line": REGEX, "group": N} to read a number from the run's summary.txt
(build, refresh and append times; "scale": 1000 turns seconds into the chart's milliseconds).

Titles state the finding and take their numbers from the plotted values: "{x0}" is the lead of
panel 0's verdict, "{v0.2}" the value of bar 2 of panel 0; a scoreboard title may use {a_wins},
{b_wins}, {level} and {n}. "require": "a" on a chart stops the script if any verdict of that
chart does not go to the first group, so a title that says "in every test" cannot outlive its data.

Every bar is labelled with its engine, its path and its value (identity never by colour alone).
Colours: one hue per engine in every figure (blue: Vertica, orange: ClickHouse), one shade per
path (dark: plain SQL; full: bitmap; light: Vertica's bitmap functions fenced). Writes NAME.svg per
chart and sources.csv (every value read, with the file it came from).
"""
import argparse
import csv
import json
import os
import re
import sys
from html import escape

SERIES = {   # fixed identity -> (label, colour); the order is the legend order
    "v_sql":     ("Vertica, plain SQL", "#104281"),
    "v_fenced":  ("Vertica bitmap database, fenced", "#86b6ef"),
    "v_bitmap":  ("Vertica bitmap database, unfenced", "#2a78d6"),
    "ch_sql":    ("ClickHouse, plain SQL", "#a3441c"),
    "ch_bitmap": ("ClickHouse bitmap functions", "#eb6834"),
}
SURFACE, INK, INK2, MUTED, GRID, AXIS = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
FONT = "system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"
W, PAD = 800, 24
LEVEL = 1.05   # a lead below 5 % is "level"


def cell(record, src, sources, optional=False):
    """One recorded value: (value, note). Appends what was read to sources."""
    path = os.path.join(record, src["run"])
    scale = src.get("scale", 1)
    if "line" in src:
        with open(os.path.join(path, "summary.txt")) as f:
            for line in f:
                m = re.search(src["line"], line)
                if m:
                    v = float(m.group(src.get("group", 1)))
                    sources.append([src["run"], "summary.txt", src["line"], v])
                    return v * scale, ""
        sys.exit(f"charts: {src['run']}: no line matching {src['line']}")
    metric = src.get("metric", "p50_ms")
    with open(os.path.join(path, "driver", "summary.csv"), newline="") as f:
        for r in csv.DictReader(f):
            if r["query"] == src["query"] and int(r["clients"]) == int(src["clients"]) and r.get("block", "") == src.get("block", r.get("block", "")):
                v = float(r[metric])
                sources.append([src["run"], "driver/summary.csv", f"{src['query']} clients={src['clients']} {metric}", v])
                failed = int(r.get("errors") or 0)   # a bar never hides failed executions
                return v * scale, (f" ({failed} of {r['n']} failed)" if failed else "")
    if optional:
        sources.append([src["run"], "driver/summary.csv", f"{src['query']} clients={src['clients']} not measured", ""])
        return None, ""
    sys.exit(f"charts: {src['run']}: no {src['query']} at {src['clients']} clients")


def value(record, bar, sources, where):
    """The value of one bar (or scoreboard side) by its "pick" rule."""
    pick = bar.get("pick")
    got = [g for g in (cell(record, s, sources, optional=(pick == "min")) for s in bar["from"]) if g[0] is not None]
    if not got:
        sys.exit(f"charts: {where}: no value")
    if pick == "median":
        if len(got) % 2 == 0:
            sys.exit(f"charts: {where}: median of an even number of runs")
        return sorted(got)[len(got) // 2]
    if pick == "sum":
        return sum(g[0] for g in got), "".join(g[1] for g in got)
    return min(got) if pick == "min" else got[0]


def fmt(v, unit):
    if unit == "s":
        return f"{v:,.0f} s" if v >= 10 else f"{v:.1f} s" if v >= 2 else f"{v:.2f} s"
    if v >= 600000:
        return f"{v / 60000:.1f} min"
    if v >= 10000:
        return f"{v / 1000:,.1f} s"
    if v >= 1000:
        return f"{v / 1000:.2f} s"
    return f"{v:,.0f} ms" if v >= 10 else f"{v:.1f} ms"


def fill(template, facts):
    """Puts computed facts into a title: {x0}, {v0.2}, {a_wins}; an unknown name stops the script."""
    def one(m):
        if m.group(1) not in facts:
            sys.exit(f"charts: no fact {m.group(1)} for '{template[:40]}...'")
        return str(facts[m.group(1)])
    return re.sub(r"\{([a-z_0-9.]+)\}", one, template)


def lead(r):
    """A lead as it is printed: 213, 6.7, 1.1."""
    return f"{r:,.0f}" if r >= 9.95 else f"{r:.1f}"


def text(x, y, s, size=12, fill=INK2, weight=None, anchor=None):
    a = f' text-anchor="{anchor}"' if anchor else ""
    w = f' font-weight="{weight}"' if weight else ""
    return f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}"{w}{a}>{escape(s)}</text>'


def marked(x, y, s, size, colour):
    """Right-aligned bold text led by a square in the colour of the engine it names."""
    mark = f'<tspan fill="{colour}">\u25a0</tspan> ' if colour else ""
    return f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{INK}" font-weight="600" text-anchor="end">{mark}{escape(s)}</text>'


def wrap(s, width):
    lines, line = [], ""
    for word in s.split():
        if line and len(line) + len(word) + 1 > width:
            lines.append(line)
            line = word
        else:
            line = (line + " " + word).strip()
    return lines + [line] if line else lines


def header(parts, title, sub, y):
    """Title (the finding) and subtitle (the setup); returns the next y."""
    for line in wrap(title, 78):
        parts.append(text(PAD, y + 18, line, 18, INK, 600))
        y += 24
    y += 6
    for line in wrap(sub, 118):
        parts.append(text(PAD, y + 12, line, 12.5, INK2))
        y += 17
    return y + 8


def bar_path(x, y, w, h, colour, tip, left=False):
    """A thin bar: square at the baseline, 4 px rounded at the data end; tip = hover text."""
    w = max(w, 4.0)
    if left:   # grows to the left of x
        d = f"M{x:.1f},{y} h{-(w - 4):.1f} a4,4 0 0 0 -4,4 v{h - 8} a4,4 0 0 0 4,4 h{w - 4:.1f} z"
    else:
        d = f"M{x:.1f},{y} h{w - 4:.1f} a4,4 0 0 1 4,4 v{h - 8} a4,4 0 0 1 -4,4 h{-(w - 4):.1f} z"
    return f'<path d="{d}" fill="{colour}"><title>{escape(tip)}</title></path>'


def finish(parts, y, title):
    H = y + PAD
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H:.0f}" viewBox="0 0 {W} {H:.0f}" '
            f'font-family="{FONT}" role="img" aria-label="{escape(title)}">'
            f'<rect width="{W}" height="{H:.0f}" fill="{SURFACE}"/>' + "".join(parts) + "</svg>\n")


def judge(name_a, a, name_b, b):
    """(winner name or None when level, lead, 'a' / 'b' / None) for two values where lower is better."""
    r = max(a, b) / min(a, b)
    if r < LEVEL:
        return None, r, None
    return (name_a, r, "a") if a < b else (name_b, r, "b")


def render_bars(name, chart, record, sources):
    unit = chart.get("unit", "ms")
    label_w, row_h, gap = 250, 22, 2
    panels, facts, wins = [], {}, {"a": 0, "b": 0, None: 0}
    for i, p in enumerate(chart["panels"]):
        vals = [value(record, b, sources, f"{name}: {p['title']}: {b['series']}") for b in p["bars"]]
        verdict = None
        if p.get("verdict"):
            name_a, group_a, name_b, group_b = p["verdict"]
            best = lambda group: min((v[0], b["series"]) for b, v in zip(p["bars"], vals) if b["series"] in group)
            (va, sa), (vb, sb) = best(group_a), best(group_b)
            who, r, side = judge(name_a, va, name_b, vb)
            wins[side] += 1
            facts[f"x{i}"] = lead(r)
            verdict = (f"{who} {lead(r)}× faster" if who else "Level", SERIES[sa if side == "a" else sb][1] if who else None)
            if chart.get("require") and side != chart["require"]:
                sys.exit(f"charts: {name}: panel '{p['title']}' does not go to the required side")
        for j, (v, _) in enumerate(vals):
            facts[f"v{i}.{j}"] = fmt(v, p.get("unit", unit))
        panels.append((p, vals, verdict))
    facts.update(a_wins=wins["a"], b_wins=wins["b"], level=wins[None], n=sum(wins.values()))
    title, sub = fill(chart["title"], facts), fill(chart.get("subtitle", ""), facts)

    parts = []
    y = header(parts, title, sub, PAD)
    used = []   # legend: the series of this chart, in fixed order
    for p, _, _ in panels:
        for b in p["bars"]:
            if b["series"] not in used:
                used.append(b["series"])
    used.sort(key=list(SERIES).index)
    lx = PAD
    for s in used:
        label, col = SERIES[s]
        label = chart.get("labels", {}).get(s, label)
        step = 18 + 6.6 * len(label) + 22
        if lx + step - 22 > W - PAD:
            lx, y = PAD, y + 20
        parts.append(f'<rect x="{lx:.1f}" y="{y + 3}" width="12" height="12" rx="3" fill="{col}"/>')
        parts.append(text(lx + 18, y + 13, label, 12))
        lx += step
    y += 32
    for p, vals, verdict in panels:
        punit = p.get("unit", unit)
        vmax = max(v for v, _ in vals)
        parts.append(text(PAD, y + 14, p["title"], 14, INK, 600))
        if verdict:   # the verdict of this test, with a swatch of the winner
            vt, vc = verdict
            parts.append(marked(W - PAD, y + 14, vt, 13, vc))
        y += 22
        x0, x1 = PAD + label_w, W - PAD - (190 if any(n for _, n in vals) else 90)
        top = y
        for b, (v, note) in zip(p["bars"], vals):
            label, col = SERIES[b["series"]]
            label = b.get("label", chart.get("labels", {}).get(b["series"], label))
            w = max(2.0, (x1 - x0) * v / vmax)
            parts.append(text(x0 - 8, y + row_h / 2 + 4, label, 12, INK2, None, "end"))
            parts.append(bar_path(x0, y + 3, w, row_h - 6, col, f"{label}: {fmt(v, punit)}{note}"))
            parts.append(text(x0 + w + 6, y + row_h / 2 + 4, fmt(v, punit) + note, 12, INK))
            y += row_h + gap
        parts.append(f'<line x1="{x0}" y1="{top}" x2="{x0}" y2="{y}" stroke="{AXIS}"/>')
        y += 14
    if chart.get("note"):
        for line in wrap(fill(chart["note"], facts), 130):
            parts.append(text(PAD, y + 12, line, 11, INK2))
            y += 15
        y += 6
    return finish(parts, y - 8, title), None


def render_scoreboard(name, chart, record, sources):
    name_a, name_b = chart["contenders"]
    col_a, col_b = SERIES[chart["colours"][0]][1], SERIES[chart["colours"][1]][1]
    rows, wins = [], {"a": 0, "b": 0, None: 0}
    for g in chart["groups"]:
        rows.append(("group", g["title"]))
        for r in g["rows"]:
            unit = r.get("unit", "ms")
            a, _ = value(record, r["a"], sources, f"{name}: {r['label']}: {name_a}")
            b, _ = value(record, r["b"], sources, f"{name}: {r['label']}: {name_b}")
            who, x, side = judge(name_a, a, name_b, b)
            wins[side] += 1
            rows.append(("row", r["label"], fmt(a, unit), fmt(b, unit), who, x, side))
    facts = dict(a_wins=wins["a"], b_wins=wins["b"], level=wins[None], n=sum(wins.values()))
    title, sub = fill(chart["title"], facts), fill(chart.get("subtitle", ""), facts)

    max_a = max([r[5] for r in rows if r[0] == "row" and r[6] == "a"] + [2.0])
    max_b = max([r[5] for r in rows if r[0] == "row" and r[6] == "b"] + [2.0])
    xa, xb = 420, 516               # right edges of the two value columns
    left, right = 548, W - PAD - 34   # the lead bars live between these, labels outside
    scale = (right - left - 34) / ((max_a - 1) + (max_b - 1))
    mid = left + 34 + (max_b - 1) * scale   # the "level" line
    parts = []
    y = header(parts, title, sub, PAD)
    # column heads
    parts.append(marked(xa, y + 12, name_a, 12.5, col_a))
    parts.append(marked(xb, y + 12, name_b, 12.5, col_b))
    y += 22
    top = y
    row_h = 23
    for r in rows:
        if r[0] == "group":
            y += 8
            parts.append(text(PAD, y + 14, r[1], 13, INK, 600))
            parts.append(f'<line x1="{PAD}" y1="{y + 21}" x2="{W - PAD}" y2="{y + 21}" stroke="{GRID}"/>')
            y += 26
            continue
        _, label, fa, fb, who, x, side = r
        parts.append(text(PAD, y + 15, label, 12, INK2))
        parts.append(text(xa, y + 15, fa, 12, INK, 600 if side == "a" else None, "end"))
        parts.append(text(xb, y + 15, fb, 12, INK, 600 if side == "b" else None, "end"))
        w = (x - 1) * scale
        if side == "a":
            parts.append(bar_path(mid + 1, y + 4, w, row_h - 9, col_a, f"{label}: {name_a} {fa}, {name_b} {fb}"))
            parts.append(text(mid + 1 + max(w, 4) + 5, y + 15, f"{lead(x)}×", 12, INK, 600))
        elif side == "b":
            parts.append(bar_path(mid - 1, y + 4, w, row_h - 9, col_b, f"{label}: {name_a} {fa}, {name_b} {fb}", left=True))
            parts.append(text(mid - 1 - max(w, 4) - 5, y + 15, f"{lead(x)}×", 12, INK, 600, "end"))
        else:
            parts.append(text(mid + 6, y + 15, "level", 12, INK2))
        y += row_h
    parts.append(f'<line x1="{mid:.1f}" y1="{top}" x2="{mid:.1f}" y2="{y + 4}" stroke="{AXIS}"/>')
    y += 8   # which way the bars point
    parts.append(text(mid - 8, y + 12, f"← {name_b} faster", 11.5, INK2, None, "end"))
    parts.append(text(mid + 8, y + 12, f"{name_a} faster →", 11.5, INK2))
    y += 26
    for line in wrap(fill(chart.get("note", ""), facts), 130):
        parts.append(text(PAD, y + 12, line, 11, INK2))
        y += 15
    # the same rows as a Markdown table, for the article
    md = [f"| Test | {name_a} | {name_b} | Faster |", "|---|---:|---:|---|"]
    for r in rows:
        if r[0] == "group":
            md.append(f"| **{r[1]}** | | | |")
        else:
            _, label, fa, fb, who, x, side = r
            a_txt, b_txt = (f"**{fa}**" if side == "a" else fa), (f"**{fb}**" if side == "b" else fb)
            md.append(f"| {label} | {a_txt} | {b_txt} | " + (f"**{who}, {lead(x)}×**" if who == name_a else f"{who}, {lead(x)}×" if who else "level") + " |")
    md.append("")
    md.append(f"{name_a} faster: {wins['a']} of {sum(wins.values())}; {name_b} faster: {wins['b']}; level: {wins[None]}.")
    return finish(parts, y, title), "\n".join(md) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--record", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    spec = json.load(open(a.spec))
    os.makedirs(a.out, exist_ok=True)
    sources = []
    for name, chart in spec.items():
        if name.startswith("_"):
            continue
        before = len(sources)
        svg, md = (render_scoreboard if chart.get("type") == "scoreboard" else render_bars)(name, chart, a.record, sources)
        for s in sources[before:]:
            s.insert(0, name)
        with open(os.path.join(a.out, name + ".svg"), "w") as f:
            f.write(svg)
        if md:
            with open(os.path.join(a.out, name + ".md"), "w") as f:
                f.write(md)
        print(f"charts: {name}.svg ({len(sources) - before} values)")
    with open(os.path.join(a.out, "sources.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["chart", "run", "file", "cell", "value"])
        w.writerows(sources)


if __name__ == "__main__":
    main()

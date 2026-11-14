#!/usr/bin/env python3
"""Two explanatory figures of the article (static drawings, no measured values)."""
import sys
from html import escape
out = sys.argv[1]
SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BLUE, ORANGE, GREEN, PINK, SOFT = "#2a78d6", "#eb6834", "#1baf7a", "#e87ba4", "#f0efeb"

def svg(w, h, parts, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
            f'font-family="Helvetica, Arial, sans-serif" role="img" aria-label="{escape(title)}">'
            f'<rect width="{w}" height="{h}" fill="{SURFACE}"/>' + "".join(parts) + "</svg>\n")

def text(x, y, s, size=12, fill=INK2, weight=None, anchor=None, mono=False):
    a = f' text-anchor="{anchor}"' if anchor else ""
    wt = f' font-weight="{weight}"' if weight else ""
    fam = ' font-family="Menlo, Consolas, monospace"' if mono else ""
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}"{wt}{a}{fam}>{escape(s)}</text>'

# ---------------------------------------------------------------- figure 1: sets as rows of bits
W, pad = 760, 24
p = [text(pad, pad + 18, "One set of IDs per predicate; a question is set algebra", 18, INK, 600),
     text(pad, pad + 40, "16 people (IDs 0 to 15). A filled cell means the person is in the set.", 13)]
ids = range(16)
rows = [("country_IL", {0, 1, 3, 4, 6, 8, 9, 11, 12, 14}, BLUE),
        ("topic_sports", {1, 2, 4, 5, 8, 9, 10, 12, 15}, BLUE),
        ("topic_finance", {2, 4, 7, 9, 13, 15}, ORANGE)]
x0, cw, ch = 250, 26, 26
y = pad + 78
for i in ids:
    p.append(text(x0 + i * cw + cw / 2 - 1, y - 8, str(i), 11, INK2, None, "middle"))
def row(label, members, colour, y, bold=False, count_label=None):
    p.append(text(x0 - 12, y + 17, label, 13, INK, 600 if bold else None, "end", mono=True))
    for i in ids:
        fill = colour if i in members else SOFT
        p.append(f'<rect x="{x0 + i * cw}" y="{y}" width="{cw - 3}" height="{ch - 3}" rx="4" fill="{fill}"/>')
        if i in members:
            p.append(text(x0 + i * cw + (cw - 3) / 2, y + 16, "1", 11, "#ffffff", 600, "middle"))
    p.append(text(x0 + 16 * cw + 10, y + 17, count_label or f"{len(members)} people", 12, INK if bold else INK2, 600 if bold else None))
for label, members, colour in rows:
    row(label, members, colour, y)
    y += ch + 8
y += 6
p.append(f'<line x1="{pad}" y1="{y}" x2="{W - pad}" y2="{y}" stroke="{GRID}"/>')
y += 14
il, sp, fi = rows[0][1], rows[1][1], rows[2][1]
row("country_IL & topic_sports", il & sp, BLUE, y)
y += ch + 8
row("… - topic_finance", (il & sp) - fi, GREEN, y, bold=True, count_label=f"= {len((il & sp) - fi)} people")
y += ch + 22
for line in ["AND keeps the IDs present in both rows, minus (AND NOT) removes the IDs of the second row, OR keeps IDs of either.",
             "The count is the number of ones; the ID list is their positions. No join, no DISTINCT: each person is one bit.",
             "Roaring compression stores each block of 65,536 IDs as a sorted list, a bitset or runs, whichever is smallest."]:
    p.append(text(pad, y, line, 12))
    y += 18
open(f"{out}/bitmap_idea.svg", "w").write(svg(W, y + pad - 8, p, "Sets of IDs as rows of bits"))

# ---------------------------------------------------------------- figure 2: how the index is built and read
p = [text(pad, pad + 18, "From source tables to an answer", 18, INK, 600),
     text(pad, pad + 40, "The index is derived data: built per snapshot, checked against its source, then published.", 13)]
def box(x, y, w, h, title, lines, colour=GRID, fill="#ffffff"):
    p.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{colour}" stroke-width="1.5"/>')
    p.append(text(x + 12, y + 22, title, 13, INK, 600))
    for i, l in enumerate(lines):
        mono = l.startswith("`")
        p.append(text(x + 12, y + 42 + i * 16, l.strip("`"), 11 if mono else 12, INK2, None, None, mono))
def arrow(x1, y1, x2, y2, label=None, colour=INK2, dash=False):
    d = ' stroke-dasharray="5 4"' if dash else ""
    p.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{colour}" stroke-width="1.5"{d} marker-end="url(#a)"/>')
    if label:
        p.append(text((x1 + x2) / 2, min(y1, y2) - 6 if y1 == y2 else (y1 + y2) / 2 + 4, label, 11, INK2, None, "middle" if y1 == y2 else None))
p.insert(0, f'<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{INK2}"/></marker></defs>')
top = pad + 64
bw, bh, gap = 222, 112, 23
xs = [pad + i * (bw + gap) for i in range(3)]
box(xs[0], top, bw, bh, "1. Source tables", ["profiles, interests, events,", "devices, assets", "(ordinary Vertica tables,", "one source snapshot per load)"])
box(xs[1], top, bw, bh, "2. Predicate families", ["one SQL query per family that", "returns (predicate, entity ID):", "`country_IL, age_25_54,`", "`topic_sports, ...`"])
box(xs[2], top, bw, bh, "3. Build", ["`bm_build`", "groups the IDs by predicate", "and ID chunk (65,536 IDs) into", "one compressed set per row"], BLUE)
arrow(xs[0] + bw, top + bh / 2, xs[1] - 2, top + bh / 2)
arrow(xs[1] + bw, top + bh / 2, xs[2] - 2, top + bh / 2)
y2 = top + bh + 58
box(xs[2], y2, bw, bh, "4. Index snapshot", ["rows (predicate, chunk, payload)", "payload at most 8 KB", "state: building → verified", "→ active → retired"], BLUE)
box(xs[1], y2, bw, bh, "5. Validate and publish", ["every set is counted again from", "the source; one transaction", "makes the snapshot active;", "rollback = publish the old one"], GREEN)
box(xs[0], y2, bw, bh, "6. Readers", ["views filtered by tenant and", "role; a query pins the active", "snapshot:", "`bm_count, bm_ids, bm_facets`"], ORANGE)
arrow(xs[2] + bw / 2, top + bh, xs[2] + bw / 2, y2 - 2)
arrow(xs[2], y2 + bh / 2, xs[1] + bw + 2, y2 + bh / 2)
arrow(xs[1], y2 + bh / 2, xs[0] + bw + 2, y2 + bh / 2)
# validation reads the source again
p.append(f'<path d="M{xs[1] + bw / 2},{y2 - 2} V{top + bh + 29} H{xs[0] + bw / 2} V{top + bh + 3}" fill="none" stroke="{GREEN}" stroke-width="1.5" stroke-dasharray="5 4" marker-end="url(#a)"/>')
p.append(text(xs[0] + bw / 2 + 12, top + bh + 24, "checked against the source", 11, INK2))
y3 = y2 + bh + 30
box(pad, y3, W - 2 * pad, 76, "Refresh", ["A change batch (touch, add, remove) is applied to the active snapshot: only the changed chunks are rewritten, the rest is copied;",
                                        "the result is a new snapshot that goes through the same validation and publish. Readers of the old snapshot are never disturbed."], GRID, SOFT)
open(f"{out}/how_it_works.svg", "w").write(svg(W, y3 + 76 + pad, p, "From source tables to an answer"))
print("figures written")

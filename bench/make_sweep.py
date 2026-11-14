#!/usr/bin/env python3
"""Writes the sweep workload of the person domain: number of predicates and selectivity.

  bench/make_sweep.py --tenant=N [--src=1] [--psnap=1] [--out=FILE]

Two sweeps, each point a native form (A) and an expression form (B+) in one answer group:
  sw.n2 / sw.n8 / sw.n32   expressions over 2, 8 and 32 predicates (country & consent & a list of
                           topics; 2: country & one topic)
  sw.s0.01 / s1 / s10 / s50  expressions of three predicates (at most one per family except
                           topics) whose selectivity is closest to
                           0.01 %, 1 %, 10 % and 50 % of the people, estimated from the predicate
                           sizes of the snapshot (bitmap_demo.bitmap_predicate) assuming
                           independence; the check pass of the driver reports the real size
The expression form is the SQL that scripts/bmq --raw --snapshot=PSNAP --echo_only prints. The
native form is written from the expression: one scan of user_profile with two-valued conditions
(a NULL attribute is in no set, as in the families of sql/families.sql), topics as EXISTS on
user_interest, an OR of topics as one EXISTS with an IN list. Needs build/bmexpr (make tools) and
the VSQL_* environment variables. Prints the workload (or writes --out) and one "sweep: ..." line
per point to stderr.
"""
import argparse
import itertools
import math
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def vsql(sql):
    out = subprocess.run(["vsql", "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql],
                         capture_output=True, text=True, check=True).stdout
    return [l.split("|") for l in out.splitlines() if l]


# ---- expression parser (grammar of src/engine/expr.h: & > - > ^ > |, parentheses) -------------

def tokenize(s):
    toks = re.findall(r"\s*([A-Za-z0-9_]+|[&|^()\-])", s)
    if "".join(toks) != re.sub(r"\s+", "", s):
        sys.exit(f"make_sweep: cannot tokenize {s!r}")
    return toks


def parse(s):
    toks = tokenize(s)
    pos = [0]
    levels = ["|", "^", "-", "&"]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def level(i):
        if i == len(levels):
            t = peek()
            pos[0] += 1
            if t == "(":
                e = level(0)
                if peek() != ")":
                    sys.exit(f"make_sweep: missing ) in {s!r}")
                pos[0] += 1
                return e
            return ("name", t)
        left = level(i + 1)
        while peek() == levels[i]:
            pos[0] += 1
            left = (levels[i], left, level(i + 1))
        return left

    e = level(0)
    if pos[0] != len(toks):
        sys.exit(f"make_sweep: trailing tokens in {s!r}")
    return e


def topic_names(e):
    if e[0] == "name":
        return [e[1][6:]] if e[1].startswith("topic_") else None
    if e[0] == "|":
        a, b = topic_names(e[1]), topic_names(e[2])
        return a + b if a is not None and b is not None else None
    return None


def native_cond(e, tenant, src, positive=True):
    """An SQL condition on profile row p for the set of expression e. In a positive position (under
    AND and OR only, and the left side of AND NOT) a NULL attribute already counts as false, so the
    plain comparison is used, which the optimizer can apply to the sort order; under NOT and XOR
    the condition is made two-valued (IS TRUE), so that a NULL attribute is in no set."""
    topics = topic_names(e)
    if topics is not None:
        lst = ", ".join("'" + t.replace("'", "''") + "'" for t in topics)
        op = f"= {lst}" if len(topics) == 1 else f"IN ({lst})"
        return (f"EXISTS (SELECT 1 FROM bitmap_demo.user_interest i WHERE i.tenant_id = {tenant} "
                f"AND i.snapshot_id = {src} AND i.entity_id = p.entity_id AND i.topic {op})")
    if e[0] == "name":
        n = e[1]
        m = re.fullmatch(r"country_(.+)", n)
        if n == "all":
            return "TRUE"
        if m:
            c = f"p.country = '{m.group(1)}'"
            return c if positive else f"({c}) IS TRUE"
        if n == "age_25_54":
            return "p.age BETWEEN 25 AND 54" if positive else "(p.age BETWEEN 25 AND 54) IS TRUE"
        fixed = {"age_known": "p.age IS NOT NULL",
                 "consent_true": "p.consent IS TRUE", "consent_false": "p.consent IS FALSE",
                 "suspended_true": "p.suspended IS TRUE", "suspended_false": "p.suspended IS FALSE"}
        if n in fixed:
            return fixed[n]
        sys.exit(f"make_sweep: no native condition for {n}")
    op = e[0]
    a = native_cond(e[1], tenant, src, positive and op != "^")
    b = native_cond(e[2], tenant, src, positive and op in "&|")
    return {"&": f"({a} AND {b})", "|": f"({a} OR {b})", "-": f"({a} AND NOT {b})",
            "^": f"(({a}) <> ({b}))"}[op]


def native_sql(expr, tenant, src):
    return ("SELECT COUNT(*) AS cnt FROM bitmap_demo.user_profile p\n"
            f"WHERE p.tenant_id = {tenant} AND p.snapshot_id = {src}\n"
            f"  AND {native_cond(parse(expr), tenant, src)}")


def bmq_sql(expr, tenant, psnap):
    out = subprocess.run([os.path.join(REPO, "scripts", "bmq"), f"--tenant={tenant}", "--raw",
                          f"--snapshot={psnap}", "--mode=count", "--echo_only", expr],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"make_sweep: bmq failed for {expr!r}: {out.stderr.strip()}")
    return out.stdout.strip().rstrip(";")


# ---- choice of expressions -------------------------------------------------------------------

def family(name):
    return name.split("_", 1)[0]   # topic, country, age, consent, suspended


def estimate(shape, a, b, c, share):
    if shape == "and3":
        return share[a] * share[b] * share[c]
    pa, pb = share[a], share[b]   # (a | b) & c
    return (pa + pb - pa * pb) * share[c]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tenant", type=int, required=True)
    ap.add_argument("--src", type=int, default=1)
    ap.add_argument("--psnap", type=int, default=1)
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    rows = vsql(f"SELECT predicate, cardinality FROM bitmap_demo.bitmap_predicate "
                f"WHERE tenant_id = {a.tenant} AND snapshot_id = {a.psnap} AND domain = 'person'")
    card = {r[0]: int(r[1]) for r in rows}
    if "all" not in card:
        sys.exit("make_sweep: the snapshot has no 'all' set")
    total = card["all"]
    share = {k: v / total for k, v in card.items()}
    topics = sorted((k for k in card if k.startswith("topic_")), key=lambda k: -card[k])
    countries = sorted((k for k in card if k.startswith("country_")), key=lambda k: -card[k])
    attrs = [k for k in ("age_25_54", "age_known", "consent_true", "consent_false",
                         "suspended_true", "suspended_false") if k in card]

    points = []
    # number of predicates: mid-popularity topics (ranks 10 to 39), country IL, consent
    mid = topics[10:40]
    points.append(("sw.n2", "country_IL & " + topics[0]))
    points.append(("sw.n8", "country_IL & consent_true & (" + " | ".join(mid[:6]) + ")"))
    points.append(("sw.n32", "country_IL & consent_true & (" + " | ".join(mid[:30]) + ")"))
    # selectivity: three predicates, at least one topic and one profile predicate
    pool_t = topics[:20] + topics[20::25]
    pool_p = countries + attrs
    for label, target in (("sw.s0.01", 0.0001), ("sw.s1", 0.01), ("sw.s10", 0.10), ("sw.s50", 0.50)):
        best = None
        for shape in ("and3", "or_and"):
            for x, y in itertools.combinations(pool_t + pool_p, 2):
                for z in pool_t + pool_p:
                    if z in (x, y):
                        continue
                    names = (x, y, z)
                    if not any(n in pool_t for n in names) or not any(n in pool_p for n in names):
                        continue
                    fams = [family(n) for n in names if family(n) != "topic"]
                    if len(fams) != len(set(fams)):
                        continue   # same family: exclusive or nested sets, not independent
                    est = estimate(shape, x, y, z, share)
                    if est <= 0:
                        continue
                    score = abs(math.log(est / target))
                    if best is None or score < best[0]:
                        best = (score, shape, x, y, z, est)
        _, shape, x, y, z, est = best
        expr = f"{x} & {y} & {z}" if shape == "and3" else f"({x} | {y}) & {z}"
        points.append((label, expr))
        print(f"sweep: point={label} target={target:.4%} estimate={est:.4%} expr={expr!r}", file=sys.stderr)

    lines = [
        "-- Sweep workload, written by bench/make_sweep.py for tenant %d (source snapshot %d, person "
        "index snapshot %d)." % (a.tenant, a.src, a.psnap),
        "-- A: native SQL written from the expression; Bplus: the SQL of scripts/bmq --raw --echo_only.",
        "-- @engine vertica", ""]
    for label, expr in points:
        n = len(set(re.findall(r"[A-Za-z0-9_]+", expr)))
        print(f"sweep: point={label} predicates={n} expr={expr!r}", file=sys.stderr)
        lines.append(f"-- {label}: {n} predicates: {expr}")
        lines.append(f"-- @query {label}.A answer={label} oracle")
        lines.append(native_sql(expr, a.tenant, a.src) + ";")
        lines.append("")
        lines.append(f"-- @query {label}.Bplus answer={label}")
        lines.append(bmq_sql(expr, a.tenant, a.psnap) + ";")
        lines.append("")
    text = "\n".join(lines)
    if a.out:
        with open(a.out, "w") as f:
            f.write(text)
    else:
        print(text)


if __name__ == "__main__":
    main()

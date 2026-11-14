#!/usr/bin/env python3
"""Writes the workload of the Database Designer comparison (plan section 17.2).

  bench/make_dbd_workload.py --workload bench/workloads/vertica.sql --var tenant=N
                             --out-workload FILE --out-queries FILE [--schema bitmap_dbd]

Takes the native queries of the workload (paths A and At) with every placeholder filled in, and
writes:
  --out-workload  a driver workload with each native query twice: as it is (on bitmap_demo, the
                  oracle stays the oracle) and on the copy schema (path D for A, Dt for At), in the
                  same answer group, so the driver checks the copy's answers against the original
  --out-queries   the copy-schema queries alone, one statement each, for
                  DESIGNER_ADD_DESIGN_QUERIES (the file must be readable by the database server)
Prints one "dbd-workload: ..." line.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import driver  # noqa: E402  (load_workload: the driver's own parser and placeholder rules)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--var", action="append", default=[], help="NAME=VALUE")
    ap.add_argument("--schema", default="bitmap_dbd")
    ap.add_argument("--out-workload", required=True)
    ap.add_argument("--out-queries", required=True)
    a = ap.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_]+", a.schema):
        sys.exit("make_dbd_workload: bad --schema")
    variables = dict(v.split("=", 1) for v in a.var)
    engine, values, session_sql, queries = driver.load_workload(a.workload, variables)

    native = [q for q in queries if q.id.rsplit(".", 1)[-1] in ("A", "At")]
    if not native:
        sys.exit("make_dbd_workload: no native queries (paths A, At) in the workload")
    lines = [f"-- Database Designer comparison, written by bench/make_dbd_workload.py from {a.workload}.",
             f"-- Each native query on bitmap_demo (A, At) and on the copy schema {a.schema} (D, Dt).",
             f"-- @engine {engine}"]
    lines += [f"-- @session {s}" for s in session_sql]
    copies = []
    for q in native:
        base, path = q.id.rsplit(".", 1)
        attrs = f" answer={q.answer}" + (" oracle" if q.oracle else "") + (" ordered" if q.ordered else "")
        lines += ["", f"-- @query {q.id}{attrs}", q.sql + ";"]
        sql = re.sub(r"\bbitmap_demo\.", a.schema + ".", q.sql)
        dpath = "D" if path == "A" else "Dt"
        copies.append(sql)
        lines += ["", f"-- @query {base}.{dpath} answer={q.answer}" + (" ordered" if q.ordered else ""),
                  sql + ";"]
    with open(a.out_workload, "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(a.out_queries, "w") as f:
        f.write("".join(s + ";\n" for s in copies))
    print(f"dbd-workload: native_queries={len(native)} schema={a.schema} "
          f"workload={a.out_workload} design_queries={a.out_queries}")


if __name__ == "__main__":
    main()

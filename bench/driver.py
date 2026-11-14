#!/usr/bin/env python3
"""Benchmark driver: runs a workload against one engine and writes raw timings.

  bench/driver.py check --workload FILE --out DIR [--var NAME=VALUE ...] [--only ID,...]
  bench/driver.py run   --workload FILE --out DIR [--clients 1,8,32] [--iterations 30]
                        [--min-per-client 2] [--warmup 2] [--var ...] [--only ...]
  bench/driver.py mixed --workload FILE --out DIR --clients 8 --duration 300 [--seed 1]
                        [--warmup-s 30] [--background CMD --background-at S] [--var ...]
                        [--weights ID=W,...] [--only ...]
  every mode: [--expect CHECK_CSV [--skip-oracles]]

check   runs every query once, serially, saves its plan and compares its answer with the oracle
        of its answer group.
run     the check, then for every query and every number of clients C: C sessions run --warmup
        executions each, wait for one another, then run the measured executions: --iterations in
        total, at least --min-per-client per session. A session that has finished its share keeps
        running the query (unmeasured) until every session has, so the load stays at C until
        the last measured execution ends. Every execution's answer is compared with the check.
mixed   C sessions pick queries at random by their weight (seeded per session) for --duration
        seconds after --warmup-s; --background runs a shell command once, --background-at seconds
        into the measured part, and records its start, end and exit status.

Workload file. Lines "-- @engine NAME", "-- @set NAME=VALUE" (default of a placeholder),
"-- @session SQL" (run when a session opens), then blocks of one statement each:
    -- @query ID answer=KEY [oracle] [ordered] [weight=W] [approx=KEY2]
    SQL ...
Queries with the same answer KEY must return the same rows; the one marked oracle is the
reference. approx=KEY2 marks an approximate path: its single numeric answer is compared with the
oracle of group KEY2 and reported as a relative error (not a mismatch). Rows are compared as a sorted list unless the query is marked ordered. ${NAME} in the
SQL is replaced by --var or @set values; an unknown placeholder is an error.

Latency is measured from sending the statement to reading the end of its result, on the client.
The engine's own time is read from the engine afterwards and stored next to it. The answer
fingerprint (row count, SHA-256 of the rows) is computed after the clock stops.

Output in DIR: workload.sql (as run), queries/ID.sql, plans/ID.txt, check.csv, raw.csv,
summary.csv, sessions.csv, notes.txt. Printed: one "bench: ..." line per query and level, and a
final "summary: ..." line. Exit status 1 if any answer differed or any execution failed.
Connection (Vertica): vsql and the VSQL_* environment variables; with --client=socket the driver
speaks Vertica's wire protocol itself (same variables; no password, or VSQL_PASSWORD sent the way
the server asks for it: clear text, or hashed with MD5 or SHA-512; no TLS, no Kerberos), so
that the clock stops when the last byte of the result has arrived, exactly as for ClickHouse, and
no client program formats the rows in between. A value that contains line feeds counts as one row
per line, as vsql prints it. (ClickHouse, -- @engine clickhouse):
HTTP to CH_HOST (default ::1) port CH_HTTP_PORT (default 8123), Python standard library only.
--expect FILE (check.csv of another run, e.g. Vertica on the same data): every answer must also
equal the oracle answer of the same key there (rows and hash). --skip-oracles (only with --expect):
the oracle queries not named in --only are not run; the answers are checked against --expect
alone (for data sizes where a native oracle takes many minutes and another run already has it).
"""
import argparse
import csv
import getpass
import hashlib
import http.client
import os
import random
import re
import select
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

MARKER = b"@@END_OF_RESULT@@"
NOTICE_RE = re.compile(rb"^(NOTICE|WARNING|INFO|HINT|DETAIL)( \d+)?:")
ERROR_RE = re.compile(rb"^(ERROR|FATAL|PANIC)( \d+)?:|^vsql:")


# ---- workload ------------------------------------------------------------------------------------

class Query:
    def __init__(self, qid, answer, oracle, ordered, weight, approx, sql):
        self.id, self.answer, self.oracle, self.ordered, self.weight, self.approx, self.sql = (
            qid, answer, oracle, ordered, weight, approx, sql)


def load_workload(path, variables):
    engine, defaults, session_sql, queries, cur = None, {}, [], [], None
    with open(path) as f:
        lines = f.read().splitlines()
    for line in lines:
        if line.startswith("-- @"):
            head = line[4:].strip()
            word, _, rest = head.partition(" ")
            if word == "engine":
                engine = rest.strip()
            elif word == "set":
                k, _, v = rest.strip().partition("=")
                defaults[k.strip()] = v.strip()
            elif word == "session":
                session_sql.append(rest.strip())
            elif word == "query":
                parts = rest.split()
                if not parts:
                    sys.exit(f"driver: {path}: @query without an ID")
                cur = {"id": parts[0], "answer": parts[0], "oracle": False, "ordered": False,
                       "weight": 0.0, "approx": "", "sql": []}
                for p in parts[1:]:
                    k, eq, v = p.partition("=")
                    if k == "answer" and eq:
                        cur["answer"] = v
                    elif k == "weight" and eq:
                        cur["weight"] = float(v)
                    elif k == "approx" and eq:
                        cur["approx"] = v
                    elif k == "oracle" and not eq:
                        cur["oracle"] = True
                    elif k == "ordered" and not eq:
                        cur["ordered"] = True
                    else:
                        sys.exit(f"driver: {path}: query {parts[0]}: unknown attribute {p}")
                queries.append(cur)
            else:
                sys.exit(f"driver: {path}: unknown directive -- @{word}")
        elif cur is not None:
            cur["sql"].append(line)
    if engine is None:
        sys.exit(f"driver: {path}: no '-- @engine' line")
    values = dict(defaults)
    values.update(variables)

    def fill(text, where):
        def sub(m):
            if m.group(1) not in values:
                sys.exit(f"driver: {where}: no value for ${{{m.group(1)}}} (use --var)")
            return values[m.group(1)]
        return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", sub, text)

    out, seen = [], set()
    for q in queries:
        body = [l for l in q["sql"] if not l.lstrip().startswith("--")]
        sql = fill("\n".join(body).strip().rstrip(";").strip(), f"query {q['id']}")
        if not sql:
            sys.exit(f"driver: query {q['id']} has no SQL")
        if q["id"] in seen:
            sys.exit(f"driver: query ID {q['id']} appears twice")
        seen.add(q["id"])
        out.append(Query(q["id"], q["answer"], q["oracle"], q["ordered"], q["weight"], q["approx"], sql))
    for key in {q.answer for q in out}:
        n = sum(1 for q in out if q.answer == key and q.oracle)
        if n > 1:
            sys.exit(f"driver: answer group {key} has {n} oracles")
    session_sql = [fill(s, "@session") for s in session_sql]
    return engine, values, session_sql, out


# ---- engines -------------------------------------------------------------------------------------

class VerticaSession:
    """One vsql process; statements are written to its stdin, the result read up to a marker."""

    cap = 0   # --statement-cap: seconds a statement may take (0 = no limit)

    def __init__(self, session_sql):
        self.session_sql = session_sql
        self._closing = False
        self._open()

    def _open(self):
        self.p = subprocess.Popen(["vsql", "-X", "-A", "-t", "-q", "-F", "|", "-P", "null=NULL"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, bufsize=0)
        self.fd = self.p.stdout.fileno()
        for s in self.session_sql:
            _, _, _, err, _ = self.execute(s)
            if err:
                raise RuntimeError(f"session statement failed: {s}: {err}")
        _, _, rows, err, _ = self.execute("SELECT session_id FROM v_monitor.current_session")
        if err or len(rows) != 1:
            raise RuntimeError(f"cannot read the session ID: {err or rows}")
        self.session_id = rows[0].decode()

    def _give_up(self):
        """The statement passed the cap: end the client, open a new session and close the old one
        on the server (its statement is cancelled with it). The client keeps its place in the run."""
        if self._closing:   # the new session does not answer either: the server is not usable
            raise RuntimeError("no answer within the statement cap while reopening the session")
        old = self.session_id
        self._closing = True
        try:
            self.p.kill()
            self.p.wait()
            self._open()
            self.execute(f"SELECT CLOSE_SESSION('{old}')")   # best effort; the answer is not used
        finally:
            self._closing = False

    def execute(self, sql):
        """Returns (t_send, t_end, rows, error, notices); times from time.perf_counter()."""
        data = sql.encode() + b";\n\\echo " + MARKER + b"\n"
        end = MARKER + b"\n"
        buf = bytearray()
        t0 = time.perf_counter()
        self.p.stdin.write(data)
        self.p.stdin.flush()
        # The marker is the last thing vsql prints for this statement.
        while not (buf.endswith(end) and (len(buf) == len(end) or buf[-len(end) - 1] == 10)):
            if self.cap:
                left = self.cap - (time.perf_counter() - t0)
                if left <= 0 or not select.select([self.fd], [], [], left)[0]:
                    self._give_up()
                    return t0, time.perf_counter(), [], \
                        f"TIMEOUT: no answer within {self.cap:g} s (statement cap); session closed", []
            b = os.read(self.fd, 1 << 20)
            if not b:
                raise RuntimeError("vsql ended unexpectedly")
            buf += b
        t1 = time.perf_counter()
        out = bytes(buf[:-len(end)])
        rows, notices, error = [], [], None
        for line in out.split(b"\n")[:-1] if out else []:
            if ERROR_RE.match(line):
                error = (error + " / " if error else "") + line.decode(errors="replace")
            elif NOTICE_RE.match(line):
                notices.append(line.decode(errors="replace"))
            else:
                rows.append(line)
        return t0, t1, rows, error, notices

    run = execute

    def close(self):
        try:
            self.p.stdin.write(b"\\q\n")
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


class WireResult:
    """The bytes of one result as they came from the server; decoded after the clock stopped."""

    def __init__(self, buf):
        self.buf = buf

    def decode(self):
        """(rows, error, notices): rows as vsql -A -t -F '|' -P null=NULL prints them."""
        buf, rows, notices, error = self.buf, [], [], None
        i, n = 0, len(buf)
        while i + 5 <= n:
            kind = buf[i]
            end = i + 1 + int.from_bytes(buf[i + 1:i + 5], "big")
            if kind == 68:      # D: data row
                cols = int.from_bytes(buf[i + 5:i + 7], "big")
                j, vals = i + 7, []
                for _ in range(cols):
                    ln = int.from_bytes(buf[j:j + 4], "big")
                    j += 4
                    if ln == 0xFFFFFFFF:
                        vals.append(b"NULL")
                    else:
                        vals.append(bytes(buf[j:j + ln]))
                        j += ln
                row = vals[0] if cols == 1 else b"|".join(vals)
                if b"\n" in row:
                    rows.extend(row.split(b"\n"))
                else:
                    rows.append(row)
            elif kind in (69, 78):   # E: error, N: notice
                fields = {f[:1]: f[1:].decode(errors="replace") for f in bytes(buf[i + 5:end]).split(b"\0") if f}
                text = f"{fields.get(b'S', 'ERROR')}: {fields.get(b'M', '')}"
                if kind == 69:
                    error = (error + " / " if error else "") + text
                else:
                    notices.append(text)
            i = end
        return rows, error, notices


class TsvResult:
    """The body of one ClickHouse answer (TabSeparated); split into rows after the clock stopped,
    with the tabs replaced by '|' (vsql's separator), so that fingerprints compare."""

    def __init__(self, body):
        self.body = body

    def decode(self):
        lines = self.body.split(b"\n")
        if lines and lines[-1] == b"":
            lines.pop()
        return [l.replace(b"\t", b"|") for l in lines], None, []


def settle(rows, error, notices):
    """Decodes a result that was kept as raw bytes (WireResult, TsvResult); other results pass
    through. The measuring threads keep results raw and the caller decodes them when the block is
    over, so that no thread splits half a million rows while another one is being timed."""
    if isinstance(rows, (WireResult, TsvResult)):
        return rows.decode()
    return rows, error, notices


class VerticaWireSession:
    """One connection speaking Vertica's wire protocol (version 3.0, text results), standard library
    only. A statement is sent as one simple-query message; the result is read up to the server's
    ready-for-query message and kept as bytes: the clock stops at the last byte, the rows are
    decoded later (WireResult)."""

    cap = 0   # --statement-cap: seconds a statement may take (0 = no limit)
    READY = b"Z\x00\x00\x00\x05"

    def __init__(self, session_sql):
        self.session_sql = session_sql
        self._closing = False
        self._open()

    def _open(self):
        host = os.environ.get("VSQL_HOST", "127.0.0.1")
        port = int(os.environ.get("VSQL_PORT", "5433"))
        user = os.environ.get("VSQL_USER") or getpass.getuser()
        database = os.environ.get("VSQL_DATABASE") or user
        self.s = socket.create_connection((host, port))
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        password = os.environ.get("VSQL_PASSWORD", "")
        # Protocol 3.0, as in the published runs. A server that stores hashed passwords asks for
        # the hash only from protocol 3.5 on and refuses a 3.0 login, so with a password the
        # driver announces 3.5; the statements and the result messages it reads are the same.
        body = struct.pack("!I", 3 << 16 | (5 if password else 0))
        for k, v in (("user", user), ("database", database), ("client_label", "bench-driver")):
            body += k.encode() + b"\0" + v.encode() + b"\0"
        self.s.sendall(struct.pack("!I", len(body) + 5) + body + b"\0")
        while True:   # authentication, then parameters up to ready-for-query
            head = self._exactly(5)
            payload = self._exactly(int.from_bytes(head[1:5], "big") - 4)
            if head[:1] == b"R":
                code = int.from_bytes(payload[:4], "big")
                if code != 0:   # 0 = logged in; anything else asks for the password in some form
                    pw = self._password_reply(code, payload[4:], user, password) + b"\0"
                    self.s.sendall(b"p" + struct.pack("!I", len(pw) + 4) + pw)
            elif head[:1] == b"E":
                raise RuntimeError("connection refused: " + payload.replace(b"\0", b" ").decode(errors="replace"))
            elif head[:1] == b"Z":
                break
        for s in self.session_sql:
            _, _, _, err, _ = self.run(s)
            if err:
                raise RuntimeError(f"session statement failed: {s}: {err}")
        _, _, rows, err, _ = self.run("SELECT session_id FROM v_monitor.current_session")
        if err or len(rows) != 1:
            raise RuntimeError(f"cannot read the session ID: {err or rows}")
        self.session_id = rows[0].decode()

    @staticmethod
    def _password_reply(code, salts, user, password):
        """The password as the server asked for it: clear text (3), or hashed twice, first with
        the user's own salt and then with the salt of this login: MD5 (5 and 65541; the user
        name is the first salt) or SHA-512 (65536 and 66048; a 16-byte user salt follows the
        login salt). The result is sent as hexadecimal text behind the name of the hash."""
        pw = password.encode()
        if code == 3:
            return pw
        if code in (5, 65541):
            name, new, first = b"md5", hashlib.md5, user.encode()
        elif code in (65536, 66048):
            name, new = b"sha512", hashlib.sha512
            first = salts[8:8 + int.from_bytes(salts[4:8], "big")]
        else:
            raise RuntimeError(f"authentication method {code} is not supported by --client=socket; use --client=vsql")
        for salt in (first, salts[:4]):
            pw = new(pw + salt).hexdigest().encode()
        return name + pw

    def _exactly(self, n):
        out = bytearray()
        while len(out) < n:
            b = self.s.recv(n - len(out))
            if not b:
                raise RuntimeError("the server closed the connection")
            out += b
        return bytes(out)

    def _give_up(self):
        """As VerticaSession._give_up: new connection, the old session closed on the server."""
        if self._closing:
            raise RuntimeError("no answer within the statement cap while reopening the session")
        old = self.session_id
        self._closing = True
        try:
            self.s.close()
            self._open()
            self.run(f"SELECT CLOSE_SESSION('{old}')")   # best effort; the answer is not used
        finally:
            self._closing = False

    def execute(self, sql):
        """Returns (t_send, t_end, WireResult, None, []); settle() gives rows, error and notices."""
        q = sql.encode() + b"\0"
        buf = bytearray()
        ready = self.READY
        t0 = time.perf_counter()
        self.s.sendall(b"Q" + struct.pack("!I", len(q) + 4) + q)
        try:
            while not (len(buf) >= 6 and buf[-6:-1] == ready):
                if self.cap:
                    left = self.cap - (time.perf_counter() - t0)
                    if left <= 0:
                        raise socket.timeout()
                    self.s.settimeout(left)
                b = self.s.recv(1 << 20)
                if not b:
                    raise RuntimeError("the server closed the connection")
                buf += b
        except socket.timeout:
            self._give_up()
            return t0, time.perf_counter(), [], \
                f"TIMEOUT: no answer within {self.cap:g} s (statement cap); session closed", []
        t1 = time.perf_counter()
        return t0, t1, WireResult(buf), None, []

    def run(self, sql):
        """execute() with the result decoded at once (statements outside the measurements)."""
        t0, t1, rows, err, notices = self.execute(sql)
        return (t0, t1) + settle(rows, err, notices)

    def close(self):
        try:
            self.s.sendall(b"X\x00\x00\x00\x04")
        except OSError:
            pass
        self.s.close()


class Vertica:
    name = "vertica"
    Session = VerticaSession

    @staticmethod
    def explain(session, sql):
        _, _, rows, err, _ = session.run("EXPLAIN " + sql)
        return err or b"\n".join(rows).decode(errors="replace")

    @staticmethod
    def clock(session):
        _, _, rows, err, _ = session.run("SELECT CLOCK_TIMESTAMP()::VARCHAR")
        if err:
            raise RuntimeError(err)
        return rows[0].decode()

    @staticmethod
    def engine_times(session, session_ids, since):
        """{session_id: [request_duration_ms, ...]} of the queries since a server time, in order."""
        ids = ", ".join("'" + s.replace("'", "''") + "'" for s in session_ids)
        sql = (f"SELECT session_id, request_duration_ms FROM v_monitor.query_requests "
               f"WHERE session_id IN ({ids}) AND start_timestamp >= '{since}'::TIMESTAMPTZ "
               f"AND request_type = 'QUERY' ORDER BY session_id, start_timestamp, statement_id")
        _, _, rows, err, _ = session.run(sql)
        if err:
            raise RuntimeError(err)
        out = {}
        for r in rows:
            sid, _, ms = r.decode().rpartition("|")
            out.setdefault(sid, []).append(ms if ms != "NULL" else "")
        return out


class ClickHouseSession:
    """One HTTP keep-alive connection to the local ClickHouse instance (bench/engines/clickhouse),
    with a server-side session (session_id) so that @session settings persist. Every statement gets
    query_id SESSION-TAG-SEQ; the engine times are read back from system.query_log by that ID.
    The body is kept as bytes (TsvResult) and split into rows after the measured block."""

    HOST, PORT = os.environ.get("CH_HOST", "::1"), int(os.environ.get("CH_HTTP_PORT", "8123"))
    _count = 0
    _count_lock = threading.Lock()
    cap = 0   # --statement-cap (seconds; 0 = no limit), sent as max_execution_time

    def __init__(self, session_sql):
        with ClickHouseSession._count_lock:
            ClickHouseSession._count += 1
            n = ClickHouseSession._count
        self.session_id = f"bench{os.getpid()}s{n}"
        self.seq = 0
        self.conn = http.client.HTTPConnection(self.HOST, self.PORT, timeout=3600)
        for s in session_sql:
            _, _, _, err, _ = self.execute(s, tag="init")
            if err:
                raise RuntimeError(f"session statement failed: {s}: {err}")

    def execute(self, sql, tag="q"):
        """Returns (t_send, t_end, TsvResult, error, notices); settle() gives the rows."""
        self.seq += 1
        fields = {"session_id": self.session_id, "session_timeout": "3600",
                  "query_id": f"{self.session_id}-{tag}-{self.seq:09d}",
                  "default_format": "TabSeparated"}
        if self.cap:   # the server ends the statement itself and answers with an exception
            fields["max_execution_time"] = str(int(self.cap))
        params = urllib.parse.urlencode(fields)
        for attempt in (1, 2):
            t0 = time.perf_counter()
            try:
                self.conn.request("POST", "/?" + params, body=sql.encode())
                resp = self.conn.getresponse()
                body = resp.read()
                break
            except (BrokenPipeError, ConnectionResetError, http.client.RemoteDisconnected,
                    http.client.CannotSendRequest) as e:
                # The server closed an idle keep-alive connection (seen 2026-11-12 on the spare
                # session that reads engine times): reconnect and send again, once. The failed
                # attempt reached no query, so the clock restarts with the retry.
                self.conn.close()
                self.conn = http.client.HTTPConnection(self.HOST, self.PORT, timeout=3600)
                if attempt == 2:
                    raise RuntimeError(f"ClickHouse connection lost twice: {e}")
        t1 = time.perf_counter()
        error = None
        if resp.status != 200 or resp.getheader("X-ClickHouse-Exception-Code"):
            error = "HTTP %d: %s" % (resp.status, body.decode(errors="replace").strip().splitlines()[0] if body else "")
            return t0, t1, [], error, []
        # An exception after the first result block arrives in the body (status already sent).
        if b"DB::Exception" in body[-4000:]:
            tail = [l for l in body[-4000:].split(b"\n") if b"DB::Exception" in l]
            return t0, t1, [], tail[-1].decode(errors="replace"), []
        return t0, t1, TsvResult(body), None, []

    def run(self, sql, tag="q"):
        """execute() with the result decoded at once (statements outside the measurements)."""
        t0, t1, rows, err, notices = self.execute(sql, tag)
        return (t0, t1) + settle(rows, err, notices)

    def close(self):
        self.conn.close()


class ClickHouse:
    name = "clickhouse"
    Session = ClickHouseSession

    @staticmethod
    def explain(session, sql):
        _, _, rows, err, _ = session.run("EXPLAIN " + sql, tag="explain")
        return err or b"\n".join(rows).decode(errors="replace")

    @staticmethod
    def clock(session):
        _, _, rows, err, _ = session.run("SELECT toString(now64(6, 'UTC'))", tag="clock")
        if err:
            raise RuntimeError(err)
        return rows[0].decode()

    @staticmethod
    def engine_times(session, session_ids, since):
        """{session_id: [query_duration_ms, ...]} of the measured-workload statements ('-q-' IDs)
        started since a server time, in order (finished and failed ones, as Vertica's query_requests)."""
        _, _, _, err, _ = session.run("SYSTEM FLUSH LOGS", tag="flush")
        if err:
            raise RuntimeError(err)
        ids = ", ".join("'" + s + "'" for s in session_ids)
        sql = (f"SELECT splitByChar('-', query_id)[1] AS sid, query_duration_ms FROM system.query_log "
               f"WHERE type IN ('QueryFinish', 'ExceptionWhileProcessing', 'ExceptionBeforeStart') "
               f"AND sid IN ({ids}) AND splitByChar('-', query_id)[2] = 'q' "
               f"AND query_start_time_microseconds >= toDateTime64('{since}', 6, 'UTC') "
               f"ORDER BY sid, query_id")
        _, _, rows, err, _ = session.run(sql, tag="times")
        if err:
            raise RuntimeError(err)
        out = {}
        for r in rows:
            sid, _, ms = r.decode().partition("|")
            out.setdefault(sid, []).append(ms)
        return out


ENGINES = {"vertica": Vertica, "clickhouse": ClickHouse}


# ---- measurement ---------------------------------------------------------------------------------

def fingerprint(rows, ordered):
    h = hashlib.sha256()
    for r in (rows if ordered else sorted(rows)):
        h.update(r)
        h.update(b"\n")
    return len(rows), h.hexdigest()[:16]


def percentile(sorted_values, p):
    """Linear interpolation between closest ranks (the common default)."""
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


class Recorder:
    def __init__(self, out):
        self.out = out
        self.raw = open(os.path.join(out, "raw.csv"), "w", newline="")
        self.rw = csv.writer(self.raw)
        self.rw.writerow(["block", "query", "clients", "client", "seq", "phase", "start_s",
                          "latency_ms", "rows", "answer_ok", "error", "engine_ms", "session_id"])
        self.notes = open(os.path.join(out, "notes.txt"), "a")

    def note(self, text):
        self.notes.write(text + "\n")
        self.notes.flush()


def load_expect(path):
    """{answer key: (rows, hash)} of the oracle queries of another run's check.csv (--expect)."""
    exp = {}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if r["oracle"] == "yes" and r["matches"] == "yes":
                exp[r["answer"]] = (int(r["rows"]), r["hash"])
    return exp


def run_check(engine, sessions, queries, out, rec, expect=None):
    """Every query once, serially, on one session: plan, answer, comparison with the oracle and,
    with --expect, with the oracle answer of the same key in another run (another engine)."""
    s = sessions[0]
    os.makedirs(os.path.join(out, "plans"), exist_ok=True)
    results = {}
    for q in queries:
        with open(os.path.join(out, "plans", q.id + ".txt"), "w") as f:
            f.write(engine.explain(s, q.sql) + "\n")
        t0, t1, rows, err, notices = s.run(q.sql)
        n, h = fingerprint(rows, q.ordered)
        results[q.id] = {"rows": n, "hash": h, "error": err, "ms": (t1 - t0) * 1000,
                         "first": rows[0].decode(errors="replace") if len(rows) == 1 else None}
        for x in notices:
            rec.note(f"check {q.id}: {x}")
        if n <= 20 and not err:
            rec.note(f"check {q.id}: answer " + " ; ".join(r.decode(errors="replace") for r in rows))
    ok_all = True
    with open(os.path.join(out, "check.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["query", "answer", "oracle", "rows", "hash", "oracle_hash", "matches", "error", "ms"])
        for q in queries:
            r = results[q.id]
            if q.approx:
                ora = next((x for x in queries if x.answer == q.approx and x.oracle), None)
                oh = results[ora.id]["hash"] if ora else ""
                try:
                    exact = float(results[ora.id]["first"])
                    rel = (float(r["first"]) - exact) / exact
                    verdict = f"approx_rel_err={rel:+.5f}"
                except (TypeError, ValueError, ZeroDivisionError, AttributeError):
                    verdict = "approx_not_comparable"
                matches = not r["error"]
            else:
                ora = next((x for x in queries if x.answer == q.answer and x.oracle), None)
                oh = results[ora.id]["hash"] if ora else ""
                same = [results[x.id]["hash"] for x in queries if x.answer == q.answer]
                matches = (not r["error"]) and (r["hash"] == oh if ora else len(set(same)) == 1)
                if expect is not None:
                    if q.answer not in expect:
                        sys.exit(f"driver: --expect has no oracle answer for {q.answer}")
                    matches = matches and (r["rows"], r["hash"]) == expect[q.answer]
                    oh = oh + "/expect=" + expect[q.answer][1]
                verdict = "yes" if matches else "NO"
            ok_all &= matches
            w.writerow([q.id, q.answer, "yes" if q.oracle else "", r["rows"], r["hash"], oh,
                        verdict, r["error"] or "", f"{r['ms']:.2f}"])
            print(f"check: query={q.id} answer={q.answer} rows={r['rows']} hash={r['hash']} "
                  f"matches={verdict} ms={r['ms']:.1f}"
                  + (f" error={r['error']!r}" if r["error"] else ""), flush=True)
    return results, ok_all


def run_block(engine, sessions, q, clients, iterations, min_per_client, warmup, expected, rec, block):
    """One query at one concurrency level; returns its summary row."""
    per_client = max(min_per_client, -(-iterations // clients))
    since = engine.clock(sessions[0])
    barrier = threading.Barrier(clients + 1)
    done = threading.Event()
    remaining = [clients]
    lock = threading.Lock()
    results = [[] for _ in range(clients)]
    marks = {}

    def worker(i):
        s = sessions[i]
        execs = results[i]
        for _ in range(warmup):
            execs.append(("warmup",) + s.execute(q.sql))
        barrier.wait()
        for k in range(per_client):
            execs.append(("measured",) + s.execute(q.sql))
        with lock:
            remaining[0] -= 1
            if remaining[0] == 0:
                marks["last"] = time.perf_counter()
                done.set()
        while not done.is_set():
            execs.append(("filler",) + s.execute(q.sql))

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(clients)]
    for t in threads:
        t.start()
    barrier.wait()
    t_start = time.perf_counter()
    unix_offset = time.time() - t_start
    for t in threads:
        t.join()
    t_end = marks["last"]
    try:
        etimes = engine.engine_times(sessions[clients] if len(sessions) > clients else sessions[0],
                                     [sessions[i].session_id for i in range(clients)], since)
    except RuntimeError as e:
        etimes = {}
        rec.note(f"block {block}: engine times not read: {e}")

    lat, errors, mismatches, in_window = [], 0, 0, 0
    eng = []
    for i in range(clients):
        sid = sessions[i].session_id
        et = etimes.get(sid, [])
        if len(et) != len(results[i]):
            rec.note(f"block {block} client {i}: {len(results[i])} executions, {len(et)} engine times: not matched")
            et = [""] * len(results[i])
        for seq, (phase, t0, t1, rows, err, notices) in enumerate(results[i]):
            rows, err, notices = settle(rows, err, notices)
            n, h = fingerprint(rows, q.ordered)
            results[i][seq] = None   # the rows of a large result are not kept
            ok = (not err) and n == expected["rows"] and h == expected["hash"]
            ms = (t1 - t0) * 1000
            rec.rw.writerow([block, q.id, clients, i, seq, phase, f"{t0 - t_start:.6f}", f"{ms:.3f}", n,
                             "yes" if ok else "NO", err or "", et[seq], sid])
            if phase == "measured":
                lat.append(ms)
                if et[seq] != "":
                    eng.append(float(et[seq]))
                errors += 1 if err else 0
                mismatches += 0 if ok or err else 1
            if phase != "warmup" and t0 >= t_start and t1 <= t_end:
                in_window += 1
    rec.raw.flush()
    lat.sort()
    eng.sort()
    window = t_end - t_start
    row = {
        "block": block, "query": q.id, "answer": q.answer, "clients": clients, "n": len(lat),
        "errors": errors, "mismatches": mismatches,
        "mean_ms": sum(lat) / len(lat), "p50_ms": percentile(lat, 50), "p95_ms": percentile(lat, 95),
        "p99_ms": percentile(lat, 99), "min_ms": lat[0], "max_ms": lat[-1],
        "engine_p50_ms": percentile(eng, 50) if eng else float("nan"),
        "throughput_qps": in_window / window if window > 0 else float("nan"), "window_s": window,
        "start_unix": t_start + unix_offset, "end_unix": t_end + unix_offset,
    }
    print(f"bench: query={q.id} clients={clients} n={row['n']} p50_ms={row['p50_ms']:.2f} "
          f"p95_ms={row['p95_ms']:.2f} p99_ms={row['p99_ms']:.2f} mean_ms={row['mean_ms']:.2f} "
          f"engine_p50_ms={row['engine_p50_ms']:.1f} qps={row['throughput_qps']:.2f} "
          f"errors={errors} mismatches={mismatches}", flush=True)
    return row


def run_mixed(engine, sessions, queries, clients, duration, warmup_s, seed, background, background_at,
              expected, rec, out):
    weighted = [q for q in queries if q.weight > 0]
    if not weighted:
        sys.exit("driver: mixed: no query has a weight")
    since = engine.clock(sessions[0])
    t_base = time.perf_counter()
    t_start = t_base + warmup_s
    t_stop = t_start + duration
    results = [[] for _ in range(clients)]

    def worker(i):
        r = random.Random(seed * 1000 + i)
        s = sessions[i]
        while time.perf_counter() < t_stop:
            q = r.choices(weighted, weights=[x.weight for x in weighted])[0]
            results[i].append((q,) + s.execute(q.sql))

    bg = {}

    def background_run():
        delay = t_start + background_at - time.perf_counter()
        if delay > 0:
            time.sleep(delay)
        bg["start"] = time.perf_counter()
        with open(os.path.join(out, "background.log"), "wb") as log:
            bg["status"] = subprocess.call(background, shell=True, stdout=log, stderr=subprocess.STDOUT)
        bg["end"] = time.perf_counter()

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(clients)]
    if background:
        threads.append(threading.Thread(target=background_run))
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    try:
        etimes = engine.engine_times(sessions[clients] if len(sessions) > clients else sessions[0],
                                     [sessions[i].session_id for i in range(clients)], since)
    except RuntimeError as e:
        etimes = {}
        rec.note(f"mixed: engine times not read: {e}")
    per_query = {}
    errors = mismatches = 0
    for i in range(clients):
        sid = sessions[i].session_id
        et = etimes.get(sid, [])
        if len(et) != len(results[i]):
            rec.note(f"mixed client {i}: {len(results[i])} executions, {len(et)} engine times: not matched")
            et = [""] * len(results[i])
        for seq, (q, t0, t1, rows, err, notices) in enumerate(results[i]):
            rows, err, notices = settle(rows, err, notices)
            n, h = fingerprint(rows, q.ordered)
            results[i][seq] = None
            ok = (not err) and n == expected[q.id]["rows"] and h == expected[q.id]["hash"]
            phase = "warmup" if t0 < t_start else "measured"
            if bg and bg["start"] <= t1 and t0 <= bg.get("end", t1):
                phase += "+background"
            ms = (t1 - t0) * 1000
            rec.rw.writerow(["mixed", q.id, clients, i, seq, phase, f"{t0 - t_start:.6f}", f"{ms:.3f}", n,
                             "yes" if ok else "NO", err or "", et[seq], sid])
            if phase.startswith("measured"):
                per_query.setdefault((q.id, "background" in phase), []).append(ms)
                errors += 1 if err else 0
                mismatches += 0 if ok or err else 1
    rows_out = []
    for (qid, during_bg), lat in sorted(per_query.items()):
        lat.sort()
        rows_out.append({"block": "mixed" + ("+background" if during_bg else ""), "query": qid,
                         "answer": next(q.answer for q in queries if q.id == qid), "clients": clients,
                         "n": len(lat), "errors": "", "mismatches": "", "mean_ms": sum(lat) / len(lat),
                         "p50_ms": percentile(lat, 50), "p95_ms": percentile(lat, 95),
                         "p99_ms": percentile(lat, 99), "min_ms": lat[0], "max_ms": lat[-1],
                         "engine_p50_ms": float("nan"), "throughput_qps": len(lat) / duration,
                         "window_s": duration})
        print(f"bench: mixed query={qid}{' during_background=yes' if during_bg else ''} clients={clients} "
              f"n={len(lat)} p50_ms={percentile(lat, 50):.2f} p95_ms={percentile(lat, 95):.2f} "
              f"p99_ms={percentile(lat, 99):.2f} qps={len(lat) / duration:.2f}", flush=True)
    if background:
        line = (f"background: status={bg.get('status')} start_s={bg['start'] - t_start:.3f} "
                f"end_s={bg['end'] - t_start:.3f} duration_s={bg['end'] - bg['start']:.3f}")
        print(line, flush=True)
        rec.note(line)
    rec.raw.flush()
    return rows_out, errors, mismatches


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["check", "run", "mixed"])
    ap.add_argument("--workload", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--var", action="append", default=[], help="NAME=VALUE")
    ap.add_argument("--only", default="", help="comma-separated query IDs to measure (their oracles are checked too)")
    ap.add_argument("--clients", default="1,8,32")
    ap.add_argument("--iterations", type=int, default=30)
    ap.add_argument("--min-per-client", type=int, default=2)
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--duration", type=float, default=300)
    ap.add_argument("--warmup-s", type=float, default=30)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--background", default="")
    ap.add_argument("--background-at", type=float, default=60)
    ap.add_argument("--weights", default="", help="ID=W,...: weights for mixed (override the workload's)")
    ap.add_argument("--expect", default="", help="check.csv of another run: every answer must also equal its oracle answer")
    ap.add_argument("--skip-oracles", action="store_true",
                    help="with --expect: do not run oracle queries outside --only")
    ap.add_argument("--statement-cap", type=float, default=0,
                    help="seconds a statement may take; a statement that passes it is recorded as an error "
                         "(TIMEOUT) and the run goes on (Vertica: the session is closed and reopened; "
                         "ClickHouse: max_execution_time). 0 = no limit")
    ap.add_argument("--client", choices=["vsql", "socket"], default="vsql",
                    help="Vertica only: vsql (one vsql process per session, the default) or socket (the driver "
                         "reads Vertica's wire protocol itself; the clock stops at the last byte of the result)")
    a = ap.parse_args()
    if a.skip_oracles and not a.expect:
        sys.exit("driver: --skip-oracles needs --expect")
    expect = load_expect(a.expect) if a.expect else None

    variables = {}
    for v in a.var:
        k, eq, val = v.partition("=")
        if not eq:
            sys.exit(f"driver: --var {v}: expected NAME=VALUE")
        variables[k] = val
    engine_name, values, session_sql, queries = load_workload(a.workload, variables)
    if engine_name not in ENGINES:
        sys.exit(f"driver: engine {engine_name} is not supported")
    engine = ENGINES[engine_name]
    if engine_name == "vertica" and a.client == "socket":
        engine.Session = VerticaWireSession
    engine.Session.cap = a.statement_cap
    if a.weights:
        ids = {q.id: q for q in queries}
        for item in a.weights.split(","):
            k, eq, w = item.partition("=")
            if not eq or k not in ids:
                sys.exit(f"driver: --weights: bad item {item}")
            ids[k].weight = float(w)
    measured = {q.id for q in queries}
    if a.only:
        wanted = set(a.only.split(","))
        measured = wanted
        unknown = wanted - {q.id for q in queries}
        if unknown:
            sys.exit(f"driver: --only: unknown query IDs {sorted(unknown)}")
        keys = {q.answer for q in queries if q.id in wanted} | {q.approx for q in queries if q.id in wanted and q.approx}
        queries = [q for q in queries if q.id in wanted
                   or (q.oracle and q.answer in keys and not a.skip_oracles)]
    levels = [int(x) for x in a.clients.split(",")]
    os.makedirs(os.path.join(a.out, "queries"), exist_ok=True)
    with open(os.path.join(a.out, "workload.sql"), "w") as f:
        f.write(f"-- @engine {engine_name}\n")
        for k, v in sorted(values.items()):
            f.write(f"-- @set {k}={v}\n")
        for s in session_sql:
            f.write(f"-- @session {s}\n")
        for q in queries:
            attrs = f" answer={q.answer}" + (" oracle" if q.oracle else "") + (" ordered" if q.ordered else "") \
                + (f" weight={q.weight:g}" if q.weight else "") + (f" approx={q.approx}" if q.approx else "")
            f.write(f"-- @query {q.id}{attrs}\n{q.sql};\n")
            with open(os.path.join(a.out, "queries", q.id + ".sql"), "w") as g:
                g.write(q.sql + ";\n")
    rec = Recorder(a.out)
    rec.note(f"driver {a.mode} started {time.strftime('%Y-%m-%dT%H:%M:%S%z')} args {sys.argv[1:]}")

    n_sessions = (max(levels) if a.mode != "check" else 1) + 1   # +1: an extra session for engine times
    sessions = [engine.Session(session_sql) for _ in range(n_sessions)]
    with open(os.path.join(a.out, "sessions.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["client", "session_id"])
        for i, s in enumerate(sessions):
            w.writerow([i, s.session_id])
    status = 0
    try:
        expected, ok = run_check(engine, sessions, queries, a.out, rec, expect)
        if not ok:
            status = 1
        summary_rows, errors, mismatches = [], 0, 0
        if a.mode == "run":
            block = 0
            for q in queries:
                if q.id not in measured:
                    continue   # an oracle added by --only: checked, not measured
                if expected[q.id]["error"]:
                    print(f"bench: query={q.id} skipped (failed in the check)", flush=True)
                    continue
                for c in levels:
                    block += 1
                    row = run_block(engine, sessions, q, c, a.iterations, a.min_per_client, a.warmup,
                                    expected[q.id], rec, block)
                    summary_rows.append(row)
                    errors += row["errors"]
                    mismatches += row["mismatches"]
        elif a.mode == "mixed":
            for c in levels:
                rows, e, m = run_mixed(engine, sessions, queries, c, a.duration, a.warmup_s, a.seed,
                                       a.background, a.background_at, expected, rec, a.out)
                summary_rows += rows
                errors += e
                mismatches += m
        if summary_rows:
            with open(os.path.join(a.out, "summary.csv"), "w", newline="") as f:
                cols = list(summary_rows[0].keys())
                w = csv.writer(f)
                w.writerow(cols)
                for r in summary_rows:
                    w.writerow([f"{r[c]:.3f}" if isinstance(r[c], float) else r[c] for c in cols])
        if errors or mismatches:
            status = 1
        print(f"summary: mode={a.mode} engine={engine_name} queries={len(queries)} levels={a.clients} "
              f"check_ok={'yes' if ok else 'no'} errors={errors} mismatches={mismatches} "
              f"valid={'yes' if status == 0 else 'no'}", flush=True)
    finally:
        for s in sessions:
            s.close()
        rec.note(f"driver ended {time.strftime('%Y-%m-%dT%H:%M:%S%z')} status {status}")
    return status


if __name__ == "__main__":
    sys.exit(main())

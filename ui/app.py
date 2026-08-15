#!/usr/bin/env python3
"""A dashboard that shows which half of the system answered, and proves it.

Three kinds of endpoint, matching the three things the page has to do:

  /api/overview      Cheap state of both halves. Safe to poll.
  /api/map/<name>    PostGIS. Geometry, so it cannot leave Postgres.
  /api/agg/<name>    Aggregates. The shape that pushes down to ClickHouse.

Every response carries the SQL that ran, how long it took, and — for the
aggregates — a verdict taken from the plan tree: whether the work was sent to
ClickHouse or whether the rows were quietly dragged back here to be counted.

That verdict is the point of the page. A dashboard that only shows numbers
cannot tell you where they came from, and "it's fast" is not evidence that
anything was pushed down.

Standard library only apart from psycopg, so the image stays small and there is
no build step to explain.
"""
import collections
import datetime as dt
import itertools
import json
import os
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import psycopg
from psycopg import ClientCursor

HERE = Path(__file__).parent
PORT = int(os.environ.get("UI_PORT", "8080"))

# Geometry lives here and never moves.
LOCAL_SCHEMA = os.environ.get("LOCAL_SCHEMA", "citibike")

# Where module 05 imported the foreign tables. Empty until then; the page says
# so plainly rather than reporting a failed pushdown.
FOREIGN_SCHEMA = os.environ.get("FOREIGN_SCHEMA", "")

# A scan of a few million rows is tens of seconds while the data still lives in
# Postgres. Without a ceiling, a few impatient clicks queue several of them at
# once; they evict each other from a shared_buffers smaller than the table and
# every one gets slower. Better to fail a query than to let the pile grow.
STATEMENT_TIMEOUT_MS = int(os.environ.get("STATEMENT_TIMEOUT_MS", "120000"))

# One heavy query at a time. Aborting a fetch in the browser only closes the
# connection — the server keeps executing, which stays visible in
# pg_stat_activity after the client has gone. So the pile-up has to be
# prevented here rather than in the page.
QUERY_SLOT = threading.Semaphore(1)

# Every query the page runs, with the verdict from its plan. In memory on
# purpose: this is a demo aid, not an audit trail, and a ring buffer cannot
# grow without bound during a long session.
LOG = collections.deque(maxlen=300)
LOG_LOCK = threading.Lock()
SEQ = itertools.count(1)


def record(kind, name, verdict, ms, rows, sql, schema=""):
    with LOG_LOCK:
        LOG.appendleft({
            "n": next(SEQ),
            "at": dt.datetime.now().strftime("%H:%M:%S"),
            "kind": kind, "name": name, "schema": schema,
            "where": verdict["where"], "verdict": verdict.get("verdict", ""),
            "detail": verdict["detail"],
            "crossed": verdict.get("rows_crossed"),
            "widest": verdict.get("rows_widest"),
            "remote_sql": verdict.get("remote_sql", ""),
            "ms": ms, "rows": rows, "sql": sql,
        })


def dsn():
    return (f"host={os.environ['PGHOST']} port={os.environ.get('PGPORT', '5432')} "
            f"user={os.environ.get('PGUSER', 'postgres')} "
            f"password={os.environ['PGPASSWORD']} "
            f"dbname={os.environ.get('PGDATABASE', 'postgres')} "
            f"sslmode={os.environ.get('PGSSLMODE', 'require')} "
            f"options='-c statement_timeout={STATEMENT_TIMEOUT_MS}'")


def connect(read_only=False):
    """A client-side-binding cursor, chosen deliberately.

    Two reasons, and the second is the one that matters here. First, the SQL
    the page displays is then the exact text that ran, rather than a template
    with $1 in it. Second, a parameterised query reaches a foreign table as a
    generic plan with placeholders, and a wrapper that cannot see the constants
    has less to push down — literals give it a WHERE clause to work with.

    `read_only` is for the SQL lab, where the text comes from whoever has the
    page open. Postgres refusing the write is a much better guarantee than any
    keyword blocklist here would be: it covers the statements nobody thought to
    ban, and it covers them inside functions and CTEs too. It has to be set
    before the first statement opens a transaction.
    """
    conn = psycopg.connect(dsn(), cursor_factory=ClientCursor)
    if read_only:
        conn.read_only = True
    return conn


# --------------------------------------------------------------------------- #
# The plan tree. Reading it is the only honest answer to "did this push down?",
# and reading it properly means walking the JSON rather than grepping the text.
# --------------------------------------------------------------------------- #

AGG_NODES = ("Aggregate", "GroupAggregate", "HashAggregate", "WindowAgg")
LOCAL_WORK = AGG_NODES + ("Sort", "Incremental Sort", "Hash Join", "Merge Join",
                          "Nested Loop", "Group", "Unique")


def flatten(node, depth=0, out=None):
    out = [] if out is None else out
    out.append({
        "type": node.get("Node Type", "?"),
        "depth": depth,
        "relation": node.get("Relation Name", ""),
        "plan_rows": node.get("Plan Rows"),
        "actual_rows": node.get("Actual Rows"),
        # postgres_fdw and pg_clickhouse both surface the text they send here.
        "remote_sql": node.get("Remote SQL", "") or node.get("Remote Query", ""),
        "remote": bool(node.get("Remote SQL") or node.get("Remote Query")
                       or node.get("Node Type") == "Foreign Scan"),
    })
    for child in node.get("Plans", []) or []:
        flatten(child, depth + 1, out)
    return out


def analyse(plan_json, fdw_ready):
    """Turn one EXPLAIN (FORMAT JSON) into a verdict plus an annotated tree.

    The distinction a text match on "Remote SQL" cannot make: a plan with no
    foreign scan at all is not "failed to push down", it is "there is nothing
    to push down to". Telling someone their query fell back when no FDW was
    ever configured is worse than saying nothing.
    """
    root = plan_json[0]["Plan"]
    nodes = flatten(root)
    foreign = [n for n in nodes if n["remote"]]

    def rows_of(n):
        return n["actual_rows"] if n["actual_rows"] is not None else n["plan_rows"]

    # The widest point of the plan — how many rows this side had to put through
    # a join, a sort or an aggregate. Against the number that crossed the wire
    # it is the whole argument: 3.4M sorted here, or 15 rows fetched.
    widest = max((rows_of(n) or 0) for n in nodes) if nodes else 0
    base = {"rows_widest": widest, "nodes": nodes}

    if not foreign:
        return dict(base,
                    where="postgres",
                    verdict="local" if fdw_ready else "no_fdw",
                    detail=("no foreign table in this plan — it read local Postgres tables"
                            if fdw_ready else
                            "no foreign tables are configured, so there is nothing to push down"),
                    rows_crossed=None, remote_sql="")

    crossed = sum(rows_of(n) or 0 for n in foreign)
    remote_sql = "\n\n".join(n["remote_sql"] for n in foreign if n["remote_sql"])
    low = remote_sql.lower()
    remote_aggregates = "group by" in low or any(
        f in low for f in ("count(", "sum(", "avg(", "min(", "max("))

    shallowest = min(n["depth"] for n in foreign)
    local_above = [n["type"] for n in nodes
                   if n["depth"] < shallowest and n["type"] in LOCAL_WORK]

    if remote_aggregates and not any(t in AGG_NODES for t in local_above):
        return dict(base, where="clickhouse", verdict="pushed",
                    detail="the remote SQL carries the aggregation — ClickHouse did the counting",
                    rows_crossed=crossed, remote_sql=remote_sql)
    if remote_aggregates:
        return dict(base, where="mixed", verdict="partial",
                    detail=f"aggregated remotely, then re-aggregated here ({', '.join(local_above)})",
                    rows_crossed=crossed, remote_sql=remote_sql)
    return dict(base, where="postgres", verdict="dragged",
                detail="the foreign scan selects columns only — every row crossed "
                       "the network to be counted here",
                rows_crossed=crossed, remote_sql=remote_sql)


def fdw_state(cur):
    cur.execute("""
        SELECT (SELECT count(*) FROM pg_extension WHERE extname = 'pg_clickhouse'),
               (SELECT count(*) FROM pg_foreign_server),
               (SELECT count(*) FROM information_schema.foreign_tables),
               (SELECT coalesce(string_agg(DISTINCT foreign_table_schema, ', '), '')
                  FROM information_schema.foreign_tables)""")
    ext, servers, ftables, fschemas = cur.fetchone()
    return {"extension": bool(ext), "servers": servers, "foreign_tables": ftables,
            "foreign_schemas": fschemas, "local_schema": LOCAL_SCHEMA,
            "foreign_schema": FOREIGN_SCHEMA, "ready": bool(ftables and FOREIGN_SCHEMA)}


def pick_schema(side, state):
    """Which schema answers the Statistics tab.

    A request parameter rather than an environment variable, because the
    interesting move is flipping between the two and watching the badge change.
    A restart to see the other half of the point is a bad demo.
    """
    if side == "local" or not state["ready"]:
        return LOCAL_SCHEMA, "local"
    if side == "foreign":
        return FOREIGN_SCHEMA, "foreign"
    return FOREIGN_SCHEMA, "foreign"          # auto: prefer the claim being made


# --------------------------------------------------------------------------- #
# PostGIS: geometry, returned as GeoJSON. None of this can move.
# --------------------------------------------------------------------------- #

MAP_QUERIES = {
    "stations": {
        "label": "Stations",
        "note": "Every dock, sized by how many bikes are in it right now. The "
                "join from the live count to the point is by bigint — geometry "
                "never leaves Postgres.",
        "sql": """
WITH latest AS (
    SELECT DISTINCT ON (station_key)
           station_key, num_bikes_available, num_ebikes_available,
           num_docks_available, polled_at
    FROM {L}.station_status
    ORDER BY station_key, polled_at DESC
)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(s.geom)::json,
      'properties', json_build_object(
          'name', s.name, 'capacity', s.capacity,
          'bikes', coalesce(l.num_bikes_available, 0),
          'ebikes', coalesce(l.num_ebikes_available, 0),
          'docks', coalesce(l.num_docks_available, 0))
  )), '[]'::json))
FROM {L}.stations s LEFT JOIN latest l USING (station_key)"""},

    "voronoi": {
        "label": "Service areas",
        "note": "ST_VoronoiPolygons over every station, clipped to the network "
                "hull. There is no ClickHouse equivalent of this.",
        "sql": """
WITH cells AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(ST_Collect(geom)))).geom AS cell
    FROM {L}.stations
), hull AS (SELECT ST_ConvexHull(ST_Collect(geom)) AS h FROM {L}.stations)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(ST_Intersection(c.cell, hull.h))::json,
      'properties', json_build_object(
          'name', s.name, 'capacity', s.capacity,
          'km2', round((ST_Area(ST_Intersection(c.cell, hull.h)::geography)/1e6)::numeric, 3))
  )), '[]'::json))
FROM cells c CROSS JOIN hull
JOIN {L}.stations s ON ST_Within(s.geom, c.cell)
WHERE ST_Area(ST_Intersection(c.cell, hull.h)::geography) > 0"""},

    "pressure": {
        "label": "Empty and full",
        "note": "How often each station has been stranded over the window we "
                "have collected. Red runs out of bikes; blue runs out of docks.",
        "sql": """
WITH agg AS (
    SELECT station_key,
           count(*) AS obs,
           100.0 * sum(CASE WHEN num_bikes_available = 0 THEN 1 ELSE 0 END)
             / count(*) AS pct_no_bikes,
           100.0 * sum(CASE WHEN num_docks_available = 0 THEN 1 ELSE 0 END)
             / count(*) AS pct_no_docks
    FROM {L}.station_status GROUP BY 1
)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(s.geom)::json,
      'properties', json_build_object(
          'name', s.name, 'observations', a.obs,
          'pct_no_bikes', round(a.pct_no_bikes::numeric, 1),
          'pct_no_docks', round(a.pct_no_docks::numeric, 1),
          'net', round((a.pct_no_docks - a.pct_no_bikes)::numeric, 1))
  )), '[]'::json))
FROM agg a JOIN {L}.stations s USING (station_key)"""},
}

# --------------------------------------------------------------------------- #
# Aggregates: the shape that travels. Written against an unqualified schema so
# the same text runs locally or against the foreign tables.
# --------------------------------------------------------------------------- #

AGG_QUERIES = {
    "hourly": {
        "label": "Fleet by hour",
        "note": "Twenty-four groups out of every row collected. The best "
                "possible ratio for a pushdown: the whole table in, a screenful out.",
        "sql": """
SELECT extract(hour FROM polled_at)::int  AS hour_utc,
       count(*)                           AS observations,
       round(avg(num_bikes_available), 1) AS avg_bikes,
       round(avg(num_docks_available), 1) AS avg_free_docks
FROM {S}.station_status
GROUP BY 1 ORDER BY 1"""},

    "busiest": {
        "label": "Busiest stations",
        "note": "Joins station_status to stations. Both are replicated, so the "
                "join itself is remote work too — swap one for a local table "
                "and the pushdown collapses.",
        "sql": """
SELECT st.name,
       count(*)                              AS observations,
       round(avg(ss.num_bikes_available), 1) AS avg_bikes,
       max(ss.num_bikes_available)           AS peak,
       min(ss.num_bikes_available)           AS trough
FROM {S}.station_status ss
JOIN {S}.stations st ON st.station_key = ss.station_key
GROUP BY st.name
HAVING count(*) >= 5
ORDER BY peak DESC LIMIT 20"""},

    "stranded": {
        "label": "Stranded riders",
        "note": "Two conditional aggregates over the whole table. Cheap to "
                "express, expensive to run locally.",
        "sql": """
SELECT st.name,
       count(*) AS observations,
       round(100.0 * sum(CASE WHEN ss.num_bikes_available = 0 THEN 1 ELSE 0 END)
             / count(*), 1) AS pct_no_bikes,
       round(100.0 * sum(CASE WHEN ss.num_docks_available = 0 THEN 1 ELSE 0 END)
             / count(*), 1) AS pct_no_docks
FROM {S}.station_status ss
JOIN {S}.stations st ON st.station_key = ss.station_key
GROUP BY st.name
HAVING count(*) >= 5
ORDER BY pct_no_bikes DESC LIMIT 20"""},

    "electric": {
        "label": "E-bike share",
        "note": "A rollup by hour. date_trunc has to reach the wrapper as a "
                "literal for this to push down, which is why the unit is not "
                "a bound parameter.",
        "sql": """
SELECT date_trunc('hour', polled_at) AS hour_utc,
       sum(num_bikes_available)      AS bikes,
       sum(num_ebikes_available)     AS ebikes,
       round(100.0 * sum(num_ebikes_available)
             / nullif(sum(num_bikes_available), 0), 1) AS pct_electric
FROM {S}.station_status
GROUP BY 1 ORDER BY 1 DESC LIMIT 48"""},
}


# --------------------------------------------------------------------------- #
# The lab. Everything above answers a question the page chose; everything below
# lets the reader ask their own, which is the difference between a demo and an
# exercise.
#
# `{S}` is the schema under test and `{L}` is always local, so the same text can
# be sent to either side — or to both at once, which is the only way to see that
# identical SQL produces two different plans.
# --------------------------------------------------------------------------- #

EXERCISES = {
    "count": {
        "label": "1 · The simplest pushdown",
        "goal": "Get a verdict of ClickHouse, and understand why this shape is the easy case.",
        "look_for": "Remote SQL should contain count(). One row comes back; nothing else crosses.",
        "side": "both",
        "sql": "SELECT count(*) AS snapshots FROM {S}.station_status",
    },
    "working_join": {
        "label": "2 · A join that stays remote",
        "goal": "Both tables are replicated, so the join is remote work too.",
        "look_for": "Remote SQL carries the JOIN and the GROUP BY. Rows crossed should be tiny.",
        "side": "both",
        "sql": """SELECT st.name, count(*) AS observations,
       round(avg(ss.num_bikes_available), 1) AS avg_bikes
FROM {S}.station_status ss
JOIN {S}.stations st ON st.station_key = ss.station_key
GROUP BY st.name
ORDER BY observations DESC
LIMIT 10""",
    },
    "broken_join": {
        "label": "3 · Break it on purpose",
        "goal": "One local table in the join collapses the pushdown — silently, with no error.",
        "look_for": "Verdict flips to Postgres. Compare 'rows crossed' with exercise 2: every "
                    "status row now comes back to be joined here.",
        "side": "foreign",
        "sql": """-- station_status is remote, stations is forced local with {L}.
-- This is the single most common way a working pushdown stops working.
SELECT st.name, count(*) AS observations,
       round(avg(ss.num_bikes_available), 1) AS avg_bikes
FROM {S}.station_status ss
JOIN {L}.stations st ON st.station_key = ss.station_key
GROUP BY st.name
ORDER BY observations DESC
LIMIT 10""",
    },
    "geometry": {
        "label": "4 · Geometry cannot cross",
        "goal": "Ask for a spatial predicate over the remote table and watch what has to happen.",
        "look_for": "ST_DWithin needs geom, which only exists locally — so the aggregate cannot "
                    "go remote no matter how simple it looks.",
        "side": "foreign",
        "sql": """-- Everything within 500 m of Grand Army Plaza.
SELECT count(*) AS observations,
       round(avg(ss.num_bikes_available), 1) AS avg_bikes
FROM {S}.station_status ss
JOIN {L}.stations st ON st.station_key = ss.station_key
WHERE ST_DWithin(st.geom::geography,
                 ST_SetSRID(ST_MakePoint(-73.9699, 40.6743), 4326)::geography,
                 500)""",
    },
    "window_covered": {
        "label": "5 · The window function that does not sort",
        "goal": "The surprise: with the module-02 index, Postgres reads straight down it.",
        "look_for": "In the plan tree, an Index Scan on status_station_time_ix and NO Sort node. "
                    "This is Postgres doing well.",
        "side": "local",
        "sql": """SELECT station_key, polled_at, num_bikes_available,
       num_bikes_available - lag(num_bikes_available)
           OVER (PARTITION BY station_key ORDER BY polled_at) AS delta
FROM {S}.station_status
ORDER BY station_key, polled_at
LIMIT 200""",
    },
    "window_uncovered": {
        "label": "6 · Now uncover the index",
        "goal": "Change the ordering and the same query has to sort. This is the honest argument.",
        "look_for": "A Sort node appears. You can index for one access path, not for all of them "
                    "— and the second question you ask is never the one you indexed for.",
        "side": "local",
        "sql": """-- Identical shape to exercise 5, ordered by a column the index does not carry.
SELECT station_key, num_bikes_available,
       num_bikes_available - lag(num_bikes_available)
           OVER (PARTITION BY station_key ORDER BY num_bikes_available) AS delta
FROM {S}.station_status
LIMIT 200""",
    },
    "your_own": {
        "label": "7 · Your own query",
        "goal": "Write anything. The transaction is read only, so you cannot break the workshop.",
        "look_for": "Whatever you were curious about. Run it on both sides and compare the plans.",
        "side": "both",
        "sql": """SELECT date_trunc('hour', polled_at) AS hour,
       count(*)                        AS observations,
       sum(num_bikes_available)        AS bikes,
       sum(num_ebikes_available)       AS ebikes
FROM {S}.station_status
GROUP BY 1
ORDER BY 1 DESC
LIMIT 24""",
    },
}

# How many result rows reach the browser. The plan is the lesson here; a lab
# query that accidentally selects a million rows should not also freeze the tab.
LAB_ROW_CAP = 500


def run_one(cur, sql, fdw_ready):
    """EXPLAIN it, run it, and return everything needed to argue about it."""
    try:
        cur.execute("EXPLAIN (VERBOSE, COSTS ON, FORMAT JSON) " + sql)
    except psycopg.errors.SyntaxError as exc:
        # EXPLAIN accepts SELECT/INSERT/UPDATE/DELETE and nothing else, so DDL
        # lands here with a caret pointing at text the reader never typed.
        # Saying what the lab is for beats leaking the prefix.
        raise ValueError(
            "this is not a query the lab can plan — EXPLAIN takes SELECT and "
            f"the DML statements only, and the transaction is read only in any "
            f"case ({str(exc).splitlines()[0]})") from None
    ran = analyse(cur.fetchone()[0], fdw_ready)
    t0 = time.perf_counter()
    cur.execute(sql)
    cols = [c.name for c in cur.description] if cur.description else []
    fetched = cur.fetchmany(LAB_ROW_CAP) if cur.description else []
    ms = round((time.perf_counter() - t0) * 1000, 1)
    rows = [[str(v) if v is not None else "" for v in r] for r in fetched]
    return {"schema_sql": sql, "columns": cols, "rows": rows, "ms": ms,
            "truncated": len(rows) >= LAB_ROW_CAP, "ran": ran}


# --------------------------------------------------------------------------- #
# Checkpoints. One per thing a module was supposed to leave behind, so a reader
# who is stuck can see which step did not take rather than guessing.
# --------------------------------------------------------------------------- #

def checks(cur, state):
    out = []

    def check(module, label, fn, hint):
        """Each check gets a savepoint.

        Without one the first failure aborts the transaction and every check
        after it reports "current transaction is aborted" instead of its own
        result — which is precisely backwards, because the checks that fail are
        the ones a reader opened this tab to read. Half these queries touch
        objects that legitimately do not exist yet (cron.job before module 03,
        the ingest schema before the FDW), so failure is the normal case here,
        not the exception.
        """
        try:
            cur.execute("SAVEPOINT chk")
            ok, detail = fn()
            cur.execute("RELEASE SAVEPOINT chk")
        except Exception as exc:                                   # noqa: BLE001
            try:
                cur.execute("ROLLBACK TO SAVEPOINT chk")
            except Exception:                                      # noqa: BLE001
                pass
            # First line only: the LINE/caret block underneath is noise in a
            # one-line status row.
            ok = False
            detail = f"{type(exc).__name__}: {str(exc).splitlines()[0]}"
        out.append({"module": module, "label": label, "ok": bool(ok),
                    "detail": detail, "hint": "" if ok else hint})

    def scalar(sql):
        cur.execute(sql)
        return cur.fetchone()

    check("02", "PostGIS is installed",
          lambda: (lambda v: (bool(v[0]), f"postgis {v[0]}" if v[0] else "not installed"))(
              scalar("SELECT (SELECT extversion FROM pg_extension WHERE extname='postgis')")),
          "Run sql/01-schema.sql.")

    check("02", "Both tables exist",
          lambda: (lambda v: (v[0] == 2, f"{v[0]} of 2 found"))(
              scalar(f"""SELECT count(*) FROM pg_class c
                           JOIN pg_namespace n ON n.oid = c.relnamespace
                          WHERE n.nspname = '{LOCAL_SCHEMA}'
                            AND c.relname IN ('stations','station_status')""")),
          "Run sql/01-schema.sql.")

    check("02", "Publication names two tables",
          lambda: (lambda v: (v[0] == 2, f"{v[0]} table(s) published"))(
              scalar("SELECT count(*) FROM pg_publication_tables WHERE pubname='citibike_pub'")),
          "Run sql/01-schema.sql. ClickPipes needs this in module 05.")

    check("03", "pg_cron job is scheduled and active",
          lambda: (lambda v: (bool(v[0]), v[1] or "no citibike-sync job"))(
              scalar("""SELECT (SELECT active FROM cron.job WHERE jobname='citibike-sync'),
                               (SELECT jobname || ' · ' || schedule FROM cron.job
                                 WHERE jobname='citibike-sync')""")),
          "Run sql/03-postgres-sync.sql.")

    check("03", "Its last run succeeded",
          lambda: (lambda v: (v[0] == 'succeeded', f"{v[0] or 'never run'}"
                              + (f" at {v[1]}" if v[1] else "")))(
              scalar("""SELECT status, to_char(start_time,'HH24:MI:SS') FROM cron.job_run_details
                         WHERE jobname='citibike-sync' ORDER BY runid DESC LIMIT 1""")),
          "Look at return_message in cron.job_run_details — usually the FDW credentials.")

    check("03", "ClickHouse landing tables are reachable",
          lambda: (lambda v: (v[0] == 2, f"{v[0]} of 2 foreign tables in citibike_ingest"))(
              scalar("""SELECT count(*) FROM information_schema.foreign_tables
                         WHERE foreign_table_schema='citibike_ingest'""")),
          "Run clickhouse/01-ingest-rmv.sql first, then sql/03-postgres-sync.sql.")

    check("03", "Data is arriving",
          lambda: (lambda v: (v[0] is not None and v[0] < 300,
                              "no rows yet" if v[0] is None
                              else f"newest snapshot {v[0]}s old ({v[1]} rows)"))(
              scalar(f"""SELECT extract(epoch FROM now()-max(polled_at))::int, count(*)
                           FROM {LOCAL_SCHEMA}.station_status""")),
          "Up to 2 minutes is normal — one schedule for the MV, one for pg_cron. "
          "Longer than that, check the two above.")

    check("05", "A replication slot is active",
          lambda: (lambda v: (v[0] is True, "active" if v[0] else
                              ("slot exists but is INACTIVE — it is retaining WAL"
                               if v[0] is False else "no slot")))(
              scalar("SELECT (SELECT active FROM pg_replication_slots LIMIT 1)")),
          "Create the ClickPipe in module 05. An inactive slot is worse than none: "
          "it retains WAL forever.")

    check("06", "Foreign tables imported for the pushdown",
          lambda: (state["ready"],
                   f"{state['foreign_tables']} foreign table(s) in "
                   f"{state['foreign_schemas'] or '(none)'}"
                   + ("" if FOREIGN_SCHEMA else "; FOREIGN_SCHEMA is not set")),
          "Run sql/40-fdw-clickhouse.sql, then set FOREIGN_SCHEMA in .env and "
          "restart the dashboard.")

    with LOG_LOCK:
        pushed = [e for e in LOG if e["where"] == "clickhouse"]
    check("06", "A pushdown has been observed in this session",
          lambda: (bool(pushed),
                   f"{len(pushed)} query/queries verdicted ClickHouse"
                   if pushed else "none yet"),
          "Open the Lab tab and run exercise 1 against ClickHouse.")

    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path, q = parsed.path, urllib.parse.parse_qs(parsed.query)
        try:
            if path in ("/", "/index.html"):
                return self._send(200, (HERE / "index.html").read_bytes(),
                                  "text/html; charset=utf-8")
            if path == "/api/catalog":
                with connect() as conn, conn.cursor() as cur:
                    state = fdw_state(cur)
                return self._send(200, json.dumps({
                    "maps": [{"key": k, "label": v["label"], "note": v["note"]}
                             for k, v in MAP_QUERIES.items()],
                    "aggs": [{"key": k, "label": v["label"], "note": v["note"]}
                             for k, v in AGG_QUERIES.items()],
                    "fdw": state}))
            if path == "/api/overview":
                return self._overview()
            if path == "/api/checks":
                with connect() as conn, conn.cursor() as cur:
                    state = fdw_state(cur)
                    return self._send(200, json.dumps(
                        {"checks": checks(cur, state), "fdw": state}))
            if path == "/api/exercises":
                return self._send(200, json.dumps({
                    "exercises": [dict(v, key=k) for k, v in EXERCISES.items()],
                    "local_schema": LOCAL_SCHEMA,
                    "foreign_schema": FOREIGN_SCHEMA}))
            if path == "/api/log":
                return self._log()
            if path.startswith("/api/map/"):
                return self._map(path.rsplit("/", 1)[1])
            if path.startswith("/api/agg/"):
                return self._agg(path.rsplit("/", 1)[1],
                                 (q.get("side", ["auto"])[0] or "auto"))
            self._send(404, json.dumps({"error": "not found"}))
        except Exception as exc:                                  # noqa: BLE001
            self._send(500, json.dumps({"error": f"{type(exc).__name__}: {exc}"}))

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            if parsed.path == "/api/run":
                return self._run(body.get("sql", ""), body.get("side", "both"))
            self._send(404, json.dumps({"error": "not found"}))
        except Exception as exc:                                  # noqa: BLE001
            self._send(500, json.dumps({"error": f"{type(exc).__name__}: {exc}"}))

    def _run(self, sql, side):
        """The lab. Arbitrary SQL, read only, on either side or on both.

        Running the same text against both schemas in one request is the point:
        two verdicts and two timings from one query is an argument, where either
        one on its own is just a number.
        """
        sql = (sql or "").strip().rstrip(";").strip()
        if not sql:
            return self._send(400, json.dumps({"error": "nothing to run"}))

        results = []
        with QUERY_SLOT, connect(read_only=True) as conn, conn.cursor() as cur:
            state = fdw_state(cur)
            wanted = (["local", "foreign"] if side == "both" else [side])
            for which in wanted:
                if which == "foreign" and not state["ready"]:
                    continue
                schema = FOREIGN_SCHEMA if which == "foreign" else LOCAL_SCHEMA
                text = sql.replace("{S}", schema).replace("{L}", LOCAL_SCHEMA)
                try:
                    r = run_one(cur, text, state["ready"])
                except Exception as exc:                           # noqa: BLE001
                    # One side failing is itself a result — exercise 4 is
                    # supposed to be refused by ClickHouse, and seeing the error
                    # next to the working side is the lesson.
                    conn.rollback()
                    results.append({"side": which, "schema": schema, "sql": text,
                                    "error": f"{type(exc).__name__}: {exc}"})
                    continue
                record("lab", side if side != "both" else which,
                       r["ran"], r["ms"], len(r["rows"]), text, schema)
                results.append(dict(r, side=which, schema=schema, sql=text))

        if not results:
            return self._send(400, json.dumps({
                "error": "no foreign tables are configured, so there is no "
                         "ClickHouse side to run against yet"}))
        self._send(200, json.dumps({"results": results, "fdw": state}))

    def _overview(self):
        """Live state of both halves. Index work, so this is safe to poll."""
        with connect() as conn, conn.cursor() as cur:
            # reltuples is -1, not 0, until the first ANALYZE — so a table that
            # has only just started filling reports a negative row count. Fall
            # back to an exact count in that window; it is cheap precisely
            # because there is not much there yet.
            cur.execute(f"""
                SELECT (SELECT count(*) FROM {LOCAL_SCHEMA}.stations),
                       (SELECT CASE WHEN reltuples < 0
                                    THEN (SELECT count(*) FROM {LOCAL_SCHEMA}.station_status)
                                    ELSE reltuples::bigint END
                          FROM pg_class
                         WHERE oid = '{LOCAL_SCHEMA}.station_status'::regclass),
                       pg_size_pretty(pg_total_relation_size('{LOCAL_SCHEMA}.station_status')),
                       (SELECT to_char(max(polled_at), 'YYYY-MM-DD HH24:MI:SS')
                          FROM {LOCAL_SCHEMA}.station_status),
                       (SELECT extract(epoch FROM now() - max(polled_at))::int
                          FROM {LOCAL_SCHEMA}.station_status),
                       current_setting('server_version'),
                       (SELECT postgis_lib_version())""")
            (stations, rows_est, size, last_poll, behind, pgver, gisver) = cur.fetchone()

            # The most recent snapshot, which is what makes this a live page
            # rather than a report.
            cur.execute(f"""
                SELECT count(*), sum(num_bikes_available), sum(num_ebikes_available),
                       sum(num_docks_available)
                FROM {LOCAL_SCHEMA}.station_status
                WHERE polled_at = (SELECT max(polled_at) FROM {LOCAL_SCHEMA}.station_status)""")
            snap = cur.fetchone()

            # Replication and the FDW are what make the second half real, so
            # the page reports whether they are actually running.
            cur.execute("""
                SELECT coalesce((SELECT state FROM pg_stat_replication LIMIT 1), 'not connected'),
                       coalesce((SELECT active::text FROM pg_replication_slots LIMIT 1), 'no slot'),
                       coalesce((SELECT pg_size_pretty(pg_wal_lsn_diff(
                            pg_current_wal_lsn(), confirmed_flush_lsn))
                          FROM pg_replication_slots LIMIT 1), '-'),
                       coalesce((SELECT string_agg(schemaname||'.'||tablename, ', ')
                          FROM pg_publication_tables), 'none')""")
            (cdc_state, slot_active, unconsumed, published) = cur.fetchone()
            state = fdw_state(cur)

            # Pillar three, made visible. The two schedulers are the only part
            # of the pipeline with nothing on your laptop to look at, so if the
            # page does not report them there is nowhere to look at all.
            pipeline = {"cron": "no job", "cron_last": "-", "cron_failures": None,
                        "landing_newest": None, "landing_lag": None}
            try:
                cur.execute("""
                    SELECT coalesce((SELECT jobname || ' · ' || schedule FROM cron.job
                                      WHERE jobname = 'citibike-sync'), 'no job'),
                           coalesce((SELECT status || ' at ' || to_char(start_time,'HH24:MI:SS')
                                       FROM cron.job_run_details WHERE jobname = 'citibike-sync'
                                      ORDER BY runid DESC LIMIT 1), '-'),
                           (SELECT count(*) FROM cron.job_run_details
                             WHERE jobname = 'citibike-sync' AND status <> 'succeeded')""")
                pipeline["cron"], pipeline["cron_last"], pipeline["cron_failures"] = cur.fetchone()
            except Exception:                                      # noqa: BLE001
                conn.rollback()

            # How far behind ClickHouse's landing table Postgres is. This is the
            # pg_cron half of the lag on its own, which is the number people
            # actually want when they ask why the dashboard is two minutes old.
            try:
                cur.execute("""
                    SELECT to_char(max(polled_at), 'HH24:MI:SS'),
                           extract(epoch FROM now() - max(polled_at))::int
                      FROM citibike_ingest.gbfs_status""")
                pipeline["landing_newest"], pipeline["landing_lag"] = cur.fetchone()
            except Exception:                                      # noqa: BLE001
                conn.rollback()

        self._send(200, json.dumps({
            "pipeline": pipeline,
            "postgres": {"version": pgver, "postgis": gisver, "stations": stations,
                         "rows_estimate": rows_est, "size": size,
                         "last_poll": last_poll, "behind_seconds": behind},
            "snapshot": {"stations": snap[0], "bikes": snap[1],
                         "ebikes": snap[2], "docks": snap[3]},
            "cdc": {"state": cdc_state, "slot_active": slot_active,
                    "unconsumed": unconsumed, "published": published},
            "fdw": state}))

    def _map(self, name):
        q = MAP_QUERIES.get(name)
        if not q:
            return self._send(404, json.dumps({"error": f"no map query {name!r}"}))
        sql = q["sql"].replace("{L}", LOCAL_SCHEMA).strip()
        with QUERY_SLOT, connect() as conn, conn.cursor() as cur:
            t0 = time.perf_counter()
            cur.execute(sql)
            geojson = cur.fetchone()[0]
            ms = round((time.perf_counter() - t0) * 1000, 1)
        n = len(geojson.get("features", []))
        ran = {"where": "postgres", "verdict": "geometry",
               "detail": "PostGIS geometry — this cannot be pushed down, and does not need to be",
               "rows_widest": n}
        record("map", name, ran, ms, n, sql, LOCAL_SCHEMA)
        self._send(200, json.dumps({"geojson": geojson, "ms": ms, "sql": sql,
                                    "note": q["note"], "ran": ran}))

    def _agg(self, name, side):
        q = AGG_QUERIES.get(name)
        if not q:
            return self._send(404, json.dumps({"error": f"no aggregate {name!r}"}))
        with QUERY_SLOT, connect() as conn, conn.cursor() as cur:
            state = fdw_state(cur)
            schema, resolved = pick_schema(side, state)
            sql = q["sql"].replace("{S}", schema).strip()
            cur.execute("EXPLAIN (VERBOSE, COSTS ON, FORMAT JSON) " + sql)
            plan = cur.fetchone()[0]
            ran = analyse(plan, state["ready"])
            t0 = time.perf_counter()
            cur.execute(sql)
            cols = [c.name for c in cur.description]
            rows = [[str(v) if v is not None else "" for v in r] for r in cur.fetchall()]
            ms = round((time.perf_counter() - t0) * 1000, 1)
        record("agg", name, ran, ms, len(rows), sql, schema)
        self._send(200, json.dumps({
            "columns": cols, "rows": rows, "ms": ms, "sql": sql, "note": q["note"],
            "schema": schema, "side": resolved, "ran": ran, "fdw": state}))

    def _log(self):
        with LOG_LOCK:
            entries = list(LOG)
        aggs = [e for e in entries if e["kind"] == "agg"]
        self._send(200, json.dumps({
            "entries": entries,
            "summary": {
                "total": len(entries),
                "aggregates": len(aggs),
                "pushed_down": sum(1 for e in aggs if e["where"] == "clickhouse"),
                "run_locally": sum(1 for e in aggs if e["where"] == "postgres"),
                "ms_clickhouse": round(sum(e["ms"] for e in aggs
                                           if e["where"] == "clickhouse"), 1),
                "ms_postgres": round(sum(e["ms"] for e in aggs
                                         if e["where"] == "postgres"), 1),
                "rows_crossed": sum(e["crossed"] or 0 for e in entries)}}))


if __name__ == "__main__":
    print(f"listening on :{PORT}; local schema {LOCAL_SCHEMA!r}, "
          f"foreign schema {FOREIGN_SCHEMA or '(none)'}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()

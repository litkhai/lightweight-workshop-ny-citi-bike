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
LOCAL_SCHEMA = os.environ.get("LOCAL_SCHEMA", "ny_citibike")

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


def search_path(force_local=False):
    """What an unqualified table name resolves to.

    This is the whole trick, and it is why the page no longer asks you to pick a
    side. With the foreign schema first, `FROM station_status` is an ordinary
    Postgres query that the planner sends to ClickHouse — no prefix, no switch,
    nothing to choose. The pushdown is not something you select; it is what
    happens, and the badge reports that it happened.

    `force_local` is the counter-example: the same text, resolved only against the
    real tables, so you can see what it costs when the routing does not happen.
    """
    if force_local or not (FOREIGN_SCHEMA and _fdw_ready_cache):
        return LOCAL_SCHEMA
    return f"{FOREIGN_SCHEMA}, {LOCAL_SCHEMA}"


# Set once per request from fdw_state(); a module-level cache only so that
# search_path() can be called without a cursor in hand.
_fdw_ready_cache = False


def connect(read_only=False, path=None):
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
    if path:
        with conn.cursor() as cur:
            cur.execute(f"SET search_path = {path}")
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

    # Whether these row counts were measured or guessed. Without ANALYZE they are
    # `Plan Rows`, i.e. the planner's estimate — and for a foreign scan that is
    # the wrapper's default guess, which pg_clickhouse puts at a flat 1000. A
    # fully pushed-down count(*) returns one row and gets reported as a thousand;
    # a local scan of 521,872 rows was estimated at 217,447. Both are the right
    # order of magnitude for the argument this page makes, and neither is a
    # measurement, so the page has to say which it is showing.
    estimated = all(n["actual_rows"] is None for n in nodes)

    # The widest point of the plan — how many rows this side had to put through
    # a join, a sort or an aggregate. Against the number that crossed the wire
    # it is the whole argument: 3.4M sorted here, or 15 rows fetched.
    widest = max((rows_of(n) or 0) for n in nodes) if nodes else 0
    base = {"rows_widest": widest, "rows_estimated": estimated, "nodes": nodes}

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
    """What is actually reachable, counted per schema rather than globally.

    `in_schema` is the number of foreign tables in FOREIGN_SCHEMA specifically,
    and `ready` depends on it. A global count is wrong the moment the database
    holds anything else — this workshop's own module 03 adds two foreign tables
    in ny_citibike_ch, and a shared service may carry another project's as
    well, so "some foreign table exists somewhere" says nothing about whether
    the pushdown schema was imported.
    """
    cur.execute("""
        SELECT (SELECT count(*) FROM pg_extension WHERE extname = 'pg_clickhouse'),
               (SELECT count(*) FROM pg_foreign_server),
               (SELECT count(*) FROM information_schema.foreign_tables),
               (SELECT coalesce(string_agg(DISTINCT foreign_table_schema, ', '), '')
                  FROM information_schema.foreign_tables),
               (SELECT count(*) FROM information_schema.foreign_tables
                 WHERE foreign_table_schema = %s)""", (FOREIGN_SCHEMA or None,))
    ext, servers, ftables, fschemas, in_schema = cur.fetchone()
    global _fdw_ready_cache
    _fdw_ready_cache = bool(FOREIGN_SCHEMA and in_schema)
    return {"extension": bool(ext), "servers": servers, "foreign_tables": ftables,
            "foreign_schemas": fschemas, "in_schema": in_schema,
            "local_schema": LOCAL_SCHEMA, "foreign_schema": FOREIGN_SCHEMA,
            "ready": bool(FOREIGN_SCHEMA and in_schema)}


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

    "flows": {
        "label": "Where rides go",
        "note": "The busiest origin-destination pairs, drawn as lines between the "
                "two docks. Trips are GENERATED — GBFS has no trip feed — but the "
                "geometry is real, and ST_MakeLine is the reason this cannot leave "
                "Postgres.",
        "sql": """
WITH od AS (
    SELECT start_station_key, end_station_key, count(*) AS trips
    FROM {L}.sim_trips
    WHERE started_at > now() - interval '24 hours'
    GROUP BY 1, 2
    HAVING count(*) >= 2
    ORDER BY trips DESC
    LIMIT 600
)
SELECT json_build_object(
  'type', 'FeatureCollection',
  'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      -- A straight line between two docks, not a route. The point is that
      -- building it needs both geometries, so it belongs here and nowhere else.
      'geometry', ST_AsGeoJSON(ST_MakeLine(a.geom, b.geom))::json,
      'properties', json_build_object(
          'from', a.name, 'to', b.name, 'trips', od.trips,
          'km', round((ST_Distance(a.geom::geography, b.geom::geography)/1000)::numeric, 2))
  )), '[]'::json))
FROM od
JOIN {L}.stations a ON a.station_key = od.start_station_key
JOIN {L}.stations b ON b.station_key = od.end_station_key
WHERE a.geom IS NOT NULL AND b.geom IS NOT NULL"""},
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

    "trip_hours": {
        "label": "Trips by hour",
        "note": "Over the generated trip table, which is far larger than "
                "station_status. Same pushdown shape — whole table in, 24 rows out "
                "— and note the two halves: 'observed' rides are anchored to real "
                "feed deltas, 'modelled' ones are the backfill.",
        "sql": """
SELECT extract(hour FROM started_at)::int AS hour_utc,
       source,
       count(*)                    AS trips,
       round(avg(duration_s))      AS avg_seconds,
       round(avg(meters))          AS avg_meters
FROM {S}.sim_trips
GROUP BY 1, 2 ORDER BY 1, 2"""},

    "trip_pairs": {
        "label": "Busiest routes",
        "note": "A self-join on the trip table plus two joins to stations — four "
                "relations, all remote when the schema is the foreign one. This is "
                "the shape that most clearly shows a join being pushed down.",
        "sql": """
SELECT a.name AS from_station,
       b.name AS to_station,
       count(*)               AS trips,
       round(avg(t.duration_s)) AS avg_seconds
FROM {S}.sim_trips t
JOIN {S}.stations a ON a.station_key = t.start_station_key
JOIN {S}.stations b ON b.station_key = t.end_station_key
GROUP BY a.name, b.name
ORDER BY trips DESC
LIMIT 20"""},

    "trip_riders": {
        "label": "Member vs casual",
        "note": "Two low-cardinality group keys over the whole table. The shares "
                "themselves are parameters of the generator, so read this as a "
                "pushdown demonstration and not as a finding about riders.",
        "sql": """
SELECT member_casual, rideable_type,
       count(*)                 AS trips,
       round(avg(duration_s))   AS avg_seconds,
       round(avg(meters))       AS avg_meters,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM {S}.sim_trips
GROUP BY 1, 2 ORDER BY trips DESC"""},
}


# --------------------------------------------------------------------------- #
# The dashboard series behind the Overview tab.
#
# All of these read the LOCAL schema on purpose. The Overview is an operational
# view of the Postgres side — "is the pipeline running, and what does the data
# look like" — and the engine comparison belongs in Statistics and the Lab, where
# choosing a side is the point. Each panel still carries its own elapsed time,
# because a chart that hides what it cost is the thing this dashboard is against.
#
# Every one is bounded. The Overview used to be a handful of index lookups and
# safe to poll; a trip aggregate over 9.8M rows is ten seconds. Seven days is
# enough to show a weekly shape and cheap enough to ask for on demand.
# --------------------------------------------------------------------------- #

DASH_WINDOW_DAYS = 7

DASH_QUERIES = {
    "ingest": {
        "label": "Snapshots arriving",
        "note": "One column per ten minutes over the last six hours. Flat is the "
                "healthy shape — every bar should be roughly stations x polls, "
                "because a complete feed reports every dock every time. Gaps are "
                "where a scheduler missed.",
        "sql": """
SELECT to_char(bucket, 'HH24:MI') AS at,
       rows
FROM (
    SELECT date_trunc('hour', polled_at)
             + floor(extract(minute FROM polled_at) / 10) * interval '10 minutes' AS bucket,
           count(*) AS rows
    FROM {L}.station_status
    WHERE polled_at > now() - interval '6 hours'
    GROUP BY 1
) t
ORDER BY bucket"""},

    "system_bikes": {
        "label": "Bikes in the system",
        "note": "Every bike sitting in a dock, summed per snapshot. This is the "
                "city's rhythm: the trough is the fleet out on the road.",
        "sql": """
SELECT to_char(polled_at, 'HH24:MI') AS at,
       sum(num_bikes_available)      AS bikes
FROM {L}.station_status
WHERE polled_at > now() - interval '6 hours'
GROUP BY polled_at ORDER BY polled_at"""},

    "fleet_hour": {
        "label": "Fleet by hour of day",
        "note": "Average bikes per dock, by hour. Columns rather than a line, and "
                "all 24 hours whether or not you have collected them — a line "
                "would draw a slope across the hours you have no data for.",
        "sql": """
WITH a AS (
    SELECT extract(hour FROM polled_at)::int AS h,
           avg(num_bikes_available) AS bikes
    FROM {L}.station_status
    GROUP BY 1
)
SELECT lpad(g::text, 2, '0')            AS hour,
       coalesce(round(a.bikes, 2), 0)   AS bikes
FROM generate_series(0, 23) g
LEFT JOIN a ON a.h = g
ORDER BY g"""},

    "dry_dist": {
        "label": "How often stations run dry",
        "note": "Stations grouped by the share of observations where they had no "
                "bike to give. Ranking the top twelve instead would just list the "
                "ones that are always empty, all at 100% — a distribution shows "
                "the shape, and the 'always' bar is the offline tail.",
        "sql": """
WITH per AS (
    SELECT station_key,
           100.0 * count(*) FILTER (WHERE num_bikes_available = 0)
             / count(*) AS pct
    FROM {L}.station_status
    GROUP BY 1
    HAVING count(*) >= 10
)
SELECT bucket, count(*) AS stations
FROM (
    SELECT CASE WHEN pct = 0    THEN 'never'
                WHEN pct < 5    THEN 'under 5%'
                WHEN pct < 20   THEN '5–20%'
                WHEN pct < 50   THEN '20–50%'
                WHEN pct < 100  THEN '50–99%'
                ELSE 'always'  END AS bucket,
           CASE WHEN pct = 0 THEN 1 WHEN pct < 5 THEN 2 WHEN pct < 20 THEN 3
                WHEN pct < 50 THEN 4 WHEN pct < 100 THEN 5 ELSE 6 END AS ord
    FROM per
) t
GROUP BY bucket, ord ORDER BY ord"""},
}

# Shown only when module 09 has been run. Both are windowed hard.
DASH_TRIP_QUERIES = {
    "trip_hour": {
        "label": "Trips by hour — weekday vs weekend",
        "note": f"Generated trips over the last {DASH_WINDOW_DAYS} days, in New York "
                "local time. Two commuter peaks on weekdays, one broad afternoon "
                "hump at the weekend.",
        "sql": """
SELECT lpad(h::text, 2, '0') AS hour,
       sum(CASE WHEN wk THEN n ELSE 0 END) AS weekday,
       sum(CASE WHEN wk THEN 0 ELSE n END) AS weekend
FROM (
    SELECT extract(hour FROM started_at AT TIME ZONE 'America/New_York')::int AS h,
           extract(isodow FROM started_at AT TIME ZONE 'America/New_York') < 6 AS wk,
           count(*) AS n
    FROM {L}.sim_trips
    WHERE started_at > now() - interval '{days} days'
    GROUP BY 1, 2
) t
GROUP BY h ORDER BY h"""},

    "trip_duration": {
        "label": "Trip length",
        "note": "Minutes, bucketed. Short and right-skewed is what a docked system "
                "looks like — and here it is also what the generator was told to do.",
        "sql": """
SELECT bucket, count(*) AS trips
FROM (
    SELECT CASE
             WHEN duration_s <  300 THEN '0–5'
             WHEN duration_s <  600 THEN '5–10'
             WHEN duration_s <  900 THEN '10–15'
             WHEN duration_s < 1800 THEN '15–30'
             WHEN duration_s < 3600 THEN '30–60'
             ELSE '60+'
           END AS bucket,
           CASE
             WHEN duration_s <  300 THEN 1 WHEN duration_s <  600 THEN 2
             WHEN duration_s <  900 THEN 3 WHEN duration_s < 1800 THEN 4
             WHEN duration_s < 3600 THEN 5 ELSE 6
           END AS ord
    FROM {L}.sim_trips
    WHERE started_at > now() - interval '{days} days'
) t
GROUP BY bucket, ord ORDER BY ord"""},
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
        "label": "1 · Plain SQL, and it goes remote",
        "goal": "Write an ordinary Postgres query with no schema prefix and watch "
                "where it runs.",
        "look_for": "Verdict: ClickHouse. Remote SQL contains count(). You did not "
                    "choose that — the planner did.",
        "compare": False,
        "sql": "SELECT count(*) AS snapshots FROM station_status",
    },
    "working_join": {
        "label": "2 · A join goes too",
        "goal": "Two tables, still no prefix, still nothing to select.",
        "look_for": "Remote SQL carries the JOIN and the GROUP BY. One Foreign Scan "
                    "node in the plan and nothing above it.",
        "compare": True,
        "sql": """SELECT st.name, count(*) AS observations,
       round(avg(ss.num_bikes_available), 1) AS avg_bikes
FROM station_status ss
JOIN stations st ON st.station_key = ss.station_key
GROUP BY st.name
ORDER BY observations DESC
LIMIT 10""",
    },
    "broken_join": {
        "label": "3 · Break it on purpose",
        "goal": "Name one table explicitly so it can only be the local copy.",
        "look_for": "Verdict flips to Postgres. Remote SQL selects columns only — "
                    "every row came back to be joined here. No error, no warning.",
        "compare": False,
        "sql": """-- {L} forces the real Postgres table instead of letting
-- search_path reach the replicated one. One prefix, and the routing is gone.
SELECT st.name, count(*) AS observations,
       round(avg(ss.num_bikes_available), 1) AS avg_bikes
FROM station_status ss
JOIN {L}.stations st ON st.station_key = ss.station_key
GROUP BY st.name
ORDER BY observations DESC
LIMIT 10""",
    },
    "geometry": {
        "label": "4 · Geometry cannot cross",
        "goal": "Ask for a spatial predicate and see which side has to answer.",
        "look_for": "ST_DWithin needs geom, and the replicated copy has no such "
                    "column — so the stations table here must be the local one, "
                    "and the aggregate cannot leave with it.",
        "compare": False,
        "sql": """-- Everything within 500 m of Grand Army Plaza.
SELECT count(*) AS observations,
       round(avg(ss.num_bikes_available), 1) AS avg_bikes
FROM station_status ss
JOIN {L}.stations st ON st.station_key = ss.station_key
WHERE ST_DWithin(st.geom::geography,
                 ST_SetSRID(ST_MakePoint(-73.9699, 40.6743), 4326)::geography,
                 500)""",
    },
    "window_covered": {
        "label": "5 · The window function that does not sort",
        "goal": "The surprise: with the module-02 index, Postgres reads straight "
                "down it. Compare, and watch which side wins.",
        "look_for": "On the Postgres-only run: an Index Scan and NO Sort node. This "
                    "is Postgres doing well.",
        "compare": True,
        "sql": """SELECT station_key, polled_at, num_bikes_available,
       num_bikes_available - lag(num_bikes_available)
           OVER (PARTITION BY station_key ORDER BY polled_at) AS delta
FROM station_status
ORDER BY station_key, polled_at
LIMIT 200""",
    },
    "window_uncovered": {
        "label": "6 · Now uncover the index",
        "goal": "Change the ordering and the same query has to sort. This is the "
                "honest argument.",
        "look_for": "A Sort node appears. You can index for one access path, not "
                    "for all of them — and the second question you ask is never "
                    "the one you indexed for.",
        "compare": True,
        "sql": """-- Identical shape to exercise 5, ordered by a column the index does not carry.
SELECT station_key, num_bikes_available,
       num_bikes_available - lag(num_bikes_available)
           OVER (PARTITION BY station_key ORDER BY num_bikes_available) AS delta
FROM station_status
LIMIT 200""",
    },
    "your_own": {
        "label": "7 · Your own query",
        "goal": "Write anything. The transaction is read only, so you cannot break "
                "the workshop.",
        "look_for": "Whatever you were curious about. Tick compare to see what the "
                    "same text costs without the routing.",
        "compare": True,
        "sql": """SELECT date_trunc('hour', polled_at) AS hour,
       count(*)                        AS observations,
       sum(num_bikes_available)        AS bikes,
       sum(num_ebikes_available)       AS ebikes
FROM station_status
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

    # The two core tables must be in it; a third is fine. Module 09 adds sim_trips
    # to the same publication, so a check for `count = 2` started failing the
    # moment the optional module ran — reporting a broken publication when nothing
    # was broken. Assert the names, and list whatever else is there.
    check("02", "Publication covers both core tables",
          lambda: (lambda v: (v[0] == 2,
                              f"stations and station_status: {v[0]} of 2"
                              + (f"; also {v[1]}" if v[1] else "")))(
              scalar("""SELECT count(*) FILTER (
                            WHERE tablename IN ('stations','station_status')),
                          string_agg(tablename, ', ' ORDER BY tablename) FILTER (
                            WHERE tablename NOT IN ('stations','station_status'))
                          FROM pg_publication_tables
                         WHERE pubname = 'ny_citibike_pub'""")),
          "Run sql/01-schema.sql. ClickPipes needs this in module 05.")

    check("03", "pg_cron job is scheduled and active",
          lambda: (lambda v: (bool(v[0]), v[1] or "no ny_citibike-sync job"))(
              scalar("""SELECT (SELECT active FROM cron.job WHERE jobname='ny_citibike-sync'),
                               (SELECT jobname || ' · ' || schedule FROM cron.job
                                 WHERE jobname='ny_citibike-sync')""")),
          "Run sql/03-postgres-sync.sql.")

    check("03", "Its last run succeeded",
          # `or (None, None)`: a scheduled job that has not fired yet returns no
          # row at all, and "never run" is the answer there — not a crash.
          lambda: (lambda v: (v[0] == 'succeeded', f"{v[0] or 'never run'}"
                              + (f" at {v[1]}" if v[1] else "")))(
              # job_run_details keys on jobid and carries no jobname column, so
              # the name has to come from cron.job. A query that assumes
              # otherwise fails with "column jobname does not exist" rather than
              # returning nothing, which is how this was caught.
              scalar("""SELECT d.status, to_char(d.start_time,'HH24:MI:SS')
                          FROM cron.job_run_details d
                          JOIN cron.job j USING (jobid)
                         WHERE j.jobname = 'ny_citibike-sync'
                         ORDER BY d.runid DESC LIMIT 1""") or (None, None)),
          "Look at return_message in cron.job_run_details — usually the FDW credentials.")

    # By name, not by count. ny_citibike_ch holds the landing tables from module
    # 03 *and* the replicated ones from module 06, so "how many foreign tables
    # are in there" is 2, 4 or 5 depending how far you have got — a count would
    # have started failing the moment the pushdown was wired up.
    check("03", "ClickHouse landing tables are reachable",
          lambda: (lambda v: (v[0] == 2,
                              f"{v[0]} of 2 landing tables in ny_citibike_ch"))(
              scalar("""SELECT count(*) FROM information_schema.foreign_tables
                         WHERE foreign_table_schema = 'ny_citibike_ch'
                           AND foreign_table_name IN ('gbfs_status','gbfs_stations')""")),
          "Run clickhouse/01-ingest-rmv.sql first, then sql/03-postgres-sync.sql.")

    check("03", "Data is arriving",
          lambda: (lambda v: (v[0] is not None and v[0] < 300,
                              "no rows yet" if v[0] is None
                              else f"newest snapshot {v[0]}s old ({v[1]} rows)"))(
              scalar(f"""SELECT extract(epoch FROM now()-max(polled_at))::int, count(*)
                           FROM {LOCAL_SCHEMA}.station_status""")),
          "Up to 2 minutes is normal — one schedule for the MV, one for pg_cron. "
          "Longer than that, check the two above.")

    # Named, not counted. There is no publisher-side column linking a slot to
    # the publication its subscriber reads, so "some slot is active" is not
    # evidence that *your* pipe is running — on a shared service it will happily
    # pass on somebody else's. Listing the names lets the reader see that, and
    # an inactive slot is called out because it retains WAL forever.
    check("05", "A replication slot exists and is consuming",
          lambda: (lambda rows: (
              bool(rows) and all(r[1] for r in rows),
              "no slot yet" if not rows else
              ", ".join(f"{r[0]} ({'active' if r[1] else 'INACTIVE — retaining WAL'})"
                        for r in rows)))(
              (cur.execute("""SELECT slot_name, active FROM pg_replication_slots
                               ORDER BY slot_name"""), cur.fetchall())[1]),
          "Create the ClickPipe in module 05. Then check the slot name belongs to "
          "it — a slot from another project on the same service proves nothing "
          "about yours, and an inactive slot retains WAL forever.")

    check("06", "Foreign tables imported for the pushdown",
          lambda: (state["ready"],
                   "FOREIGN_SCHEMA is not set" if not FOREIGN_SCHEMA else
                   f"{state['in_schema']} foreign table(s) in {FOREIGN_SCHEMA}"
                   f" (all schemas: {state['foreign_schemas'] or 'none'})"),
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
        # Never cache. index.html carries all the JS, so a cached copy survives
        # `docker compose up --build` and silently runs the old dashboard against
        # the new API — which looks like the new code is broken. Cost is one small
        # file per load; the confusion it prevents is worth far more than that.
        self.send_header("Cache-Control", "no-store, must-revalidate")
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
            if path == "/api/dashboard":
                return self._dashboard()
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
                return self._agg(path.rsplit("/", 1)[1])
            self._send(404, json.dumps({"error": "not found"}))
        except Exception as exc:                                  # noqa: BLE001
            self._send(500, json.dumps({"error": f"{type(exc).__name__}: {exc}"}))

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            if parsed.path == "/api/run":
                return self._run(body.get("sql", ""),
                                 bool(body.get("compare")))
            self._send(404, json.dumps({"error": "not found"}))
        except Exception as exc:                                  # noqa: BLE001
            self._send(500, json.dumps({"error": f"{type(exc).__name__}: {exc}"}))

    def _run(self, sql, compare=False):
        """The lab. Arbitrary SQL, read only, no side to pick.

        The query runs exactly as written, against a search_path that reaches the
        foreign tables first. Whether the work goes to ClickHouse is the planner's
        decision and the verdict reports it — which is the demonstration. Asking
        the reader to choose an engine first made the badge tautological.

        `compare` re-runs the same text with the foreign schema out of the path, so
        the counter-example is an extra step rather than a precondition.
        """
        sql = (sql or "").strip().rstrip(";").strip()
        if not sql:
            return self._send(400, json.dumps({"error": "nothing to run"}))

        results = []
        with QUERY_SLOT, connect(read_only=True) as probe, probe.cursor() as pc:
            state = fdw_state(pc)

        modes = [("as written", False)]
        if compare and state["ready"]:
            modes.append(("Postgres only", True))

        for label, force_local in modes:
            path = search_path(force_local=force_local)
            with QUERY_SLOT, connect(read_only=True, path=path) as conn, \
                 conn.cursor() as cur:
                # `{S}.` drops out entirely — an unqualified name is the point now.
                # Replacing `{S}` alone would leave a leading dot and a syntax
                # error. `{L}.` still resolves, because forcing one side by name
                # is exactly what the counter-example needs.
                text = sql.replace("{S}.", "").replace("{L}", LOCAL_SCHEMA)
                try:
                    r = run_one(cur, text, state["ready"])
                except Exception as exc:                           # noqa: BLE001
                    conn.rollback()
                    results.append({"mode": label, "search_path": path, "sql": text,
                                    "error": f"{type(exc).__name__}: {exc}"})
                    continue
                record("lab", label, r["ran"], r["ms"], len(r["rows"]), text, path)
                results.append(dict(r, mode=label, search_path=path, sql=text))

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
                       -- First word only. Debian and Ubuntu packages append their
                       -- packaging string to server_version, so a card that shows
                       -- the setting verbatim reads
                       -- "18.4 (Ubuntu 18.4-1.pgdg22.04+1)".
                       split_part(current_setting('server_version'), ' ', 1),
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

            # Replication, scoped to this workshop.
            #
            # The old version aggregated pg_publication_tables with no WHERE, so
            # the card listed every publication on the server: another project's
            # tables, and ours twice over because two publications name them. It
            # also labelled a boolean `active` as "slot". None of that describes
            # the pipeline, which is the one thing this card is for.
            cur.execute("""
                SELECT (SELECT count(*) FROM pg_publication_tables
                         WHERE pubname = 'ny_citibike_pub'),
                       coalesce((SELECT string_agg(tablename, ', ' ORDER BY tablename)
                          FROM pg_publication_tables
                         WHERE pubname = 'ny_citibike_pub'), ''),
                       (SELECT count(*) FROM pg_replication_slots),
                       (SELECT count(*) FROM pg_replication_slots WHERE NOT active),
                       coalesce((SELECT pg_size_pretty(sum(pg_wal_lsn_diff(
                            pg_current_wal_lsn(), confirmed_flush_lsn)))
                          FROM pg_replication_slots), '-'),
                       coalesce((SELECT string_agg(DISTINCT state, ', ')
                          FROM pg_stat_replication), 'not connected')""")
            (pub_n, pub_tables, slots, slots_idle, unconsumed, cdc_state) = cur.fetchone()
            state = fdw_state(cur)

            # Deliberately absent: the two ingestion schedulers.
            #
            # They are how the data arrives, not what this workshop is about — and
            # the landing-freshness probe crossed the FDW to ClickHouse on every
            # 30-second poll to report it. "Is data arriving" is already answered
            # by `last poll` on the snapshots tile, and module 03's health has a
            # proper home in the Checks tab.

        self._send(200, json.dumps({
            "postgres": {"version": pgver, "postgis": gisver, "stations": stations,
                         "rows_estimate": rows_est, "size": size,
                         "last_poll": last_poll, "behind_seconds": behind},
            "snapshot": {"stations": snap[0], "bikes": snap[1],
                         "ebikes": snap[2], "docks": snap[3]},
            "cdc": {"state": cdc_state, "slots": slots, "slots_idle": slots_idle,
                    "unconsumed": unconsumed, "publication": "ny_citibike_pub",
                    "pub_tables": pub_n, "pub_list": pub_tables},
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

    def _dashboard(self):
        """Every Overview chart in one round trip, each timed on its own.

        Deliberately not polled. The cheap cards above it refresh themselves; a
        trip aggregate does not belong on a 30-second timer, and pretending
        otherwise is how a dashboard quietly becomes the heaviest client on the
        database.
        """
        panels = []
        with QUERY_SLOT, connect(read_only=True, path=LOCAL_SCHEMA) as conn, \
             conn.cursor() as cur:
            has_trips = False
            try:
                cur.execute(f"SELECT count(*) FROM {LOCAL_SCHEMA}.sim_trips")
                has_trips = cur.fetchone()[0] > 0
            except Exception:                                      # noqa: BLE001
                conn.rollback()          # module 09 not run; the table is absent

            wanted = list(DASH_QUERIES.items())
            if has_trips:
                wanted += list(DASH_TRIP_QUERIES.items())

            for key, q in wanted:
                # str.replace, not %-formatting: these queries contain literal
                # per-cent signs in their bucket labels.
                sql = (q["sql"].replace("{L}", LOCAL_SCHEMA)
                               .replace("{days}", str(DASH_WINDOW_DAYS))).strip()
                try:
                    t0 = time.perf_counter()
                    cur.execute(sql)
                    cols = [c.name for c in cur.description]
                    rows = [list(r) for r in cur.fetchall()]
                    ms = round((time.perf_counter() - t0) * 1000, 1)
                except Exception as exc:                           # noqa: BLE001
                    conn.rollback()
                    panels.append({"key": key, "label": q["label"], "note": q["note"],
                                   "error": f"{type(exc).__name__}: "
                                            f"{str(exc).splitlines()[0]}"})
                    continue
                # Decimal from round() is not JSON-serialisable.
                rows = [[float(v) if hasattr(v, "quantize") else v for v in r]
                        for r in rows]
                panels.append({"key": key, "label": q["label"], "note": q["note"],
                               "columns": cols, "rows": rows, "ms": ms, "sql": sql})
                record("dash", key, {"where": "postgres", "verdict": "local",
                                     "detail": "Overview panel, local schema",
                                     "rows_widest": len(rows)},
                       ms, len(rows), sql, LOCAL_SCHEMA)

        self._send(200, json.dumps({"panels": panels, "schema": LOCAL_SCHEMA,
                                    "window_days": DASH_WINDOW_DAYS,
                                    "has_trips": has_trips}))

    def _agg(self, name):
        """One aggregate, written without a schema prefix.

        There is no side to choose. The connection's search_path puts the foreign
        schema first when it exists, so `FROM station_status` is a plain Postgres
        query that the planner routes to ClickHouse on its own — and the verdict
        below reports where it actually went. Offering a Postgres/ClickHouse
        switch here made the answer a restatement of the question.
        """
        q = AGG_QUERIES.get(name)
        if not q:
            return self._send(404, json.dumps({"error": f"no aggregate {name!r}"}))
        with connect() as probe, probe.cursor() as pc:
            state = fdw_state(pc)
        path = search_path()
        with QUERY_SLOT, connect(path=path) as conn, conn.cursor() as cur:
            sql = (q["sql"].replace("{S}.", "")
                           .replace("{L}.", LOCAL_SCHEMA + ".")).strip()
            cur.execute("EXPLAIN (VERBOSE, COSTS ON, FORMAT JSON) " + sql)
            ran = analyse(cur.fetchone()[0], state["ready"])
            t0 = time.perf_counter()
            cur.execute(sql)
            cols = [c.name for c in cur.description]
            rows = [[str(v) if v is not None else "" for v in r]
                    for r in cur.fetchall()]
            ms = round((time.perf_counter() - t0) * 1000, 1)
        record("agg", name, ran, ms, len(rows), sql, path)
        self._send(200, json.dumps({
            "columns": cols, "rows": rows, "ms": ms, "sql": sql, "note": q["note"],
            "search_path": path, "ran": ran, "fdw": state}))

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

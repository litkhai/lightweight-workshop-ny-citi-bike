# 07 — The dashboard

**[Previous](06-pushdown.md) · [Workshop home](index.md) · [Next: Wrap-up and teardown](08-wrap-up.md)**

## Goal

Put both halves on one page and let it label every query with the engine that
answered.

## Start it

```bash
docker compose up -d --build ui
open http://localhost:8080
```

Same `.env` as everything else. Standard library plus `psycopg`; no framework,
no build step, no bundle.

## The six tabs

| Tab | What it shows |
|---|---|
| **Overview** | Three headline numbers, the Postgres ↔ ClickHouse round trip with live state, and — on demand — six charts |
| **Maps** | The three PostGIS queries as GeoJSON — stations sized by availability, Voronoi service areas, and where riders get stranded |
| **Statistics** | Seven aggregates written with no schema prefix, each badged with where the planner actually sent it, plus its plan tree |
| **Lab** | Your own SQL, run as written. Seven exercises, and one checkbox to re-run with the routing off |
| **Checks** | One pass/fail checkpoint per thing each module should have left behind |
| **Log** | Every query the session ran, with elapsed time, rows returned, and how many rows crossed the wire |

Each tab is addressable — `http://localhost:8080/#lab` opens the lab directly.

## What to actually look at

Open **Statistics** and read one query. There is no engine to pick — the SQL has
**no schema prefix at all**:

```sql
SELECT extract(hour FROM polled_at)::int AS hour_utc, count(*), …
FROM station_status
GROUP BY 1
```

That is an ordinary Postgres query. The connection's `search_path` is
`ny_citibike_ch, ny_citibike`, so `station_status` resolves to the foreign table
first, and the planner decides on its own to send the work to ClickHouse. The
badge reports that decision; it is not a restatement of a button you pressed.

There used to be a Postgres/ClickHouse switch here. It made the badge
tautological — choose ClickHouse, be told it ran on ClickHouse — and it buried the
actual claim, which is that **you connect to one database, write one dialect, and
the heavy half goes elsewhere without being asked.**

Two things to read on each result:

- the **badge** — `ran on ClickHouse` / `ran on Postgres`
- the **Remote SQL** — the exact text that left, with the aggregation in it

!!! warning "The row counts are estimates, and the page marks them `~`"
    They come from `EXPLAIN` without `ANALYZE`, so they are `Plan Rows` — the
    planner's guess. For a foreign scan the guess is the wrapper's flat default,
    which `pg_clickhouse` puts at **1000** however many rows actually cross. A
    fully pushed-down `count(*)` returns one row and gets reported as a thousand.

    The right order of magnitude is enough to make the argument, and the ratio
    is real. But if you want the measured number, run `EXPLAIN (ANALYZE)`
    yourself — and notice that the dashboard does not, because that would mean
    executing every query twice.

!!! tip "Before module 06 the same queries say Postgres"
    With no foreign tables, `search_path` is just `ny_citibike` and every verdict
    comes back local. Nothing is broken and nothing is hidden — finish module 06,
    set `FOREIGN_SCHEMA=ny_citibike_ch` in `.env`, `docker compose up -d ui`, and
    the identical queries start reporting ClickHouse **without one character
    changing**. That is the demonstration.

## The Lab — where you stop reading and start asking

Open **Lab**. This is the tab that makes the dashboard an exercise rather than a
demo: you write the SQL, and the page tells you where it ran.

Write plain SQL. No prefix, no selector:

```sql
SELECT count(*) FROM station_status;
```

It pushes down, and the badge says so. One placeholder exists, and only for the
counter-example:

```sql
{L}.stations    -- force the real local table, opting out of the routing
```

The checkbox beside **Run** re-runs the identical text with the foreign schema
taken out of `search_path`, so you get both plans side by side when you want them
— an extra, not a precondition. Measured on the same join: **146 ms** and a single
`Foreign Scan` against **299 ms** and an eight-node plan with a 514,325-row hash
join.

The seven presets are the workshop's own "try this" list, made clickable:

| | Exercise | The point |
|---|---|---|
| 1 | Plain SQL, and it goes remote | no prefix, no choice — the planner routes it |
| 2 | A join goes too | both tables replicated, so the join travels with them |
| 3 | **Break it on purpose** | swap one table for `{L}` and watch the verdict flip |
| 4 | Geometry cannot cross | `ST_DWithin` needs `geom`, and only the local table has it |
| 5 | The window function that does not sort | the module-02 index covers it exactly |
| 6 | Now uncover the index | change the ordering and a `Sort` node appears |
| 7 | Your own query | anything you were curious about |

Exercises 5 and 6 are a pair, and worth running back to back. Identical shape,
one changed `ORDER BY`, and the plan tree gains a `Sort` — which is the honest
version of the argument for moving analytical work: not "Postgres is slow at
window functions", but "you can index for one access path and not for all of
them."

!!! tip "You cannot break anything from here"
    The lab runs in a **read-only transaction**. `DELETE`, `UPDATE` and `INSERT`
    are refused by Postgres itself rather than by a keyword filter here, which
    is a much stronger guarantee — it covers the statements nobody thought to
    ban. Type whatever you like.

## Checks — what did not take

Open **Checks** when something is not working. It runs one query per thing a
module was supposed to leave behind and tells you which step did not happen,
with the file to re-run:

```text
✓ 02  PostGIS is installed                    postgis 3.6.4
✓ 02  Both tables exist                       2 of 2 found
✗ 03  pg_cron job is scheduled and active     no ny_citibike-sync job
      → Run sql/03-postgres-sync.sql.
✓ 03  Data is arriving                        newest snapshot 76s old
✗ 05  A replication slot is active            no slot
      → Create the ClickPipe in module 05.
```

Failures here are normal while you are working through the modules — the tab is
a map of where you are, not a test you are failing.

## How the verdict is decided

The page runs `EXPLAIN (VERBOSE, COSTS ON, FORMAT JSON)` before each aggregate
and **walks the plan tree** rather than grepping the text:

| Plan | Verdict |
|---|---|
| no foreign scan, no FDW configured | Postgres — nothing to push down to |
| no foreign scan, FDW exists | Postgres — read local tables |
| remote SQL carries the aggregation, no aggregate node above it | **ClickHouse** |
| aggregated remotely, then re-aggregated locally | Mixed |
| foreign scan selects columns only | Postgres — every row crossed |

The "no aggregate node above the shallowest foreign scan" condition is what
separates a real pushdown from a partial one. Without it, a plan that
aggregates remotely and then re-aggregates locally reads as a clean win when it
is really half a win.

## Two deliberate constraints

**One heavy query at a time.** The page holds a single slot. Several concurrent
scans of a table larger than `shared_buffers` evict each other and all of them
get slower — better to fail a query than to let the pile grow. This has to be
enforced server-side, because aborting a fetch in the browser only closes the
connection; Postgres keeps executing, which stays visible in
`pg_stat_activity` after the client has gone.

**The log is in memory.** A 300-entry ring buffer, gone when the container
stops. A demo aid, not an audit trail.

**A blocked map costs you the map only.** MapLibre comes from a CDN and needs
WebGL, and a locked-down laptop may have neither. The Maps tab then says so and
every other tab carries on — worth knowing, because the alternative behaviour
(one failing constructor blanking the whole page) is much harder to diagnose
than a missing map.

## Implementation notes

`ui/README.md` in the repository covers the endpoints, the environment
variables and the plan-walking logic in more detail. The whole dashboard is two
files.

## Next

[08 — Wrap-up and teardown](08-wrap-up.md)

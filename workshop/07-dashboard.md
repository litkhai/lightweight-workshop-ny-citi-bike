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
| **Overview** | Live state of the whole pipeline: station count, snapshots collected, what is docked right now, **both schedulers**, replication slot and lag, whether the FDW is configured |
| **Maps** | The three PostGIS queries as GeoJSON — stations sized by availability, Voronoi service areas, and where riders get stranded |
| **Statistics** | The four aggregates, with a **Postgres / ClickHouse switch**, each badged with its plan verdict and its plan tree |
| **Lab** | Your own SQL, run against either side or **both at once**. Seven exercises to start from |
| **Checks** | One pass/fail checkpoint per thing each module should have left behind |
| **Log** | Every query the session ran, with elapsed time, rows returned, and how many rows crossed the wire |

Each tab is addressable — `http://localhost:8080/#lab` opens the lab directly.

## What to actually look at

Open **Statistics** and flip the side switch back and forth on the same query.

Two things change, and only one of them is the point:

- the **badge** — `ran on Postgres` / `ran on ClickHouse`
- the **row counts** — how many rows crossed the wire against how many the widest plan node handled

That second pair is the argument. *3.4M rows sorted here* versus *20 rows
fetched* says something a duration cannot. Expand **Remote SQL** to see the
exact text that went to ClickHouse.

!!! tip "If the switch is not there"
    The side switch only appears once `FOREIGN_SCHEMA` is set and foreign
    tables exist. Before that the page says so plainly instead of showing a
    disabled button, because "not configured yet" and "broken" should not look
    the same. Set `FOREIGN_SCHEMA=citibike_ch` in `.env` and
    `docker compose up -d ui` again.

## The Lab — where you stop reading and start asking

Open **Lab**. This is the tab that makes the dashboard an exercise rather than a
demo: you write the SQL, and the page tells you where it ran.

Two placeholders do the work:

```sql
{S}.station_status    -- the schema under test: local or foreign
{L}.stations          -- always local
```

Because the schema is substituted rather than typed, the same text can go to
**both sides in one request** — two plans, two timings, side by side. That
comparison is the entire argument of this workshop, and it is the one thing a
single number can never make.

The seven presets are the workshop's own "try this" list, made clickable:

| | Exercise | The point |
|---|---|---|
| 1 | The simplest pushdown | whole table in, one row out — the easy case |
| 2 | A join that stays remote | both tables replicated, so the join goes too |
| 3 | **Break it on purpose** | swap one table for `{L}` and watch the verdict flip |
| 4 | Geometry cannot cross | `ST_DWithin` needs `geom`, which only exists locally |
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
✗ 03  pg_cron job is scheduled and active     no citibike-sync job
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

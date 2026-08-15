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

## The four tabs

| Tab | What it shows |
|---|---|
| **Overview** | Live state of both halves: station count, snapshots collected, what is docked right now, replication slot and lag, whether the FDW is configured |
| **Maps** | The three PostGIS queries as GeoJSON — stations sized by availability, Voronoi service areas, and where riders get stranded |
| **Statistics** | The four aggregates, with a **Postgres / ClickHouse switch**, each badged with its plan verdict |
| **Log** | Every query the session ran, with elapsed time, rows returned, and how many rows crossed the wire |

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

## Implementation notes

`ui/README.md` in the repository covers the endpoints, the environment
variables and the plan-walking logic in more detail. The whole dashboard is two
files.

## Next

[07 — Wrap-up and teardown](08-wrap-up.md)

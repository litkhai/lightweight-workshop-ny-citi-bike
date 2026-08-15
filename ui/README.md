# `ui/` — how the dashboard works

Implementation notes. What the tabs *show* is in
[module 07](../workshop/07-dashboard.md); this is what is behind them.

Two files: `app.py` (stdlib plus `psycopg`) and `index.html` (no build step, no
bundle). The image is `python:3.12-slim` with `psycopg[binary]`.

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `LOCAL_SCHEMA` | `bike` | Where the geometry lives. Maps always read this |
| `FOREIGN_SCHEMA` | *(empty)* | Where `sql/40-fdw-clickhouse.sql` imported the foreign tables. Set it and Statistics gains a side switch |
| `UI_PORT` | `8080` | Listen port |
| `STATEMENT_TIMEOUT_MS` | `120000` | Server-side ceiling on any one query |
| `PG*` | from `.env` | Standard libpq variables |

Leaving `FOREIGN_SCHEMA` empty is a supported state, not a broken one. The page
reports that **there is nothing to push down to** — a different statement from
"the pushdown failed", and conflating the two would be the most misleading
thing this page could do.

## Endpoints

| Endpoint | Returns |
|---|---|
| `GET /api/catalog` | Query list and current FDW state |
| `GET /api/overview` | Both halves: counts, size, lag, replication slot, FDW. Index work, safe to poll |
| `GET /api/map/<name>` | GeoJSON from PostGIS: `stations`, `voronoi`, `pressure` |
| `GET /api/agg/<name>` | One aggregate: `hourly`, `busiest`, `stranded`, `electric`. `?side=auto\|local\|foreign` |
| `GET /api/log` | The session ring buffer and its totals |

Every query response carries the SQL that ran, the elapsed time, and the
verdict.

## The verdict

`analyse()` walks `EXPLAIN (VERBOSE, COSTS ON, FORMAT JSON)` as a tree rather
than grepping the text, because the plan is the only honest answer to "did this
push down?" — a fast query proves nothing when Postgres will happily pull
millions of rows across the wire and count them locally.

| Verdict | Condition | Reported as |
|---|---|---|
| `no_fdw` | no foreign scan, no FDW configured | Postgres — nothing to push down to |
| `local` | no foreign scan, but an FDW exists | Postgres — read local tables |
| `pushed` | remote SQL carries the aggregation, no aggregate node above the shallowest foreign scan | **ClickHouse** |
| `partial` | aggregated remotely, then re-aggregated here | Mixed |
| `dragged` | foreign scan selects columns only | Postgres — every row crossed |

Separating `no_fdw` from `local` is the reason for the tree walk. Both look
identical to a check for the string `Remote SQL`.

Alongside the verdict, each plan yields two numbers that carry the argument:
**rows crossed** (summed over the foreign scans) against **widest node** (the
most rows any single node handled).

## Three decisions worth knowing

**Client-side parameter binding** (`ClientCursor`). Partly so the SQL the page
displays is the exact text that ran instead of a template with `$1` in it. But
mainly because a parameterised query reaches a foreign table as a generic plan
with placeholders, and a wrapper that cannot see the constants has less to push
down.

**`COSTS` stays on** even though no cost is displayed. Turning it off also
removes `Plan Rows`, and the estimated width of a foreign scan is exactly what
the un-analyzed view is for — 20 rows coming back versus 3.4 million is the
difference this page exists to show.

**One heavy query at a time**, enforced by a semaphore. Several concurrent
scans of a table larger than `shared_buffers` evict each other and all of them
get slower. It has to be enforced server-side: aborting a fetch in the browser
only closes the connection, and Postgres keeps executing.

## Deliberately not production

- The log is a 300-entry in-memory ring buffer. A demo aid, not an audit trail.
- No authentication. Read-only queries against your workshop database — keep it on localhost.
- MapLibre GL JS loads from `unpkg.com`, so the map needs internet. Everything else works against the database alone.

## License

[MIT](../LICENSE). MapLibre GL JS is fetched at run time under its own licence
and is not vendored here.

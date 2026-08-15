# `ui/` — how the dashboard works

Implementation notes. What the tabs *show* is in
[module 07](../workshop/07-dashboard.md); this is what is behind them.

Two files: `app.py` (stdlib plus `psycopg`) and `index.html` (no build step, no
bundle). The image is `python:3.12-slim` with `psycopg[binary]`.

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `LOCAL_SCHEMA` | `citibike` | Where the geometry lives. Maps always read this |
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
| `GET /api/overview` | Both halves: counts, size, lag, both schedulers, replication slot, FDW. Index work, safe to poll |
| `GET /api/map/<name>` | GeoJSON from PostGIS: `stations`, `voronoi`, `pressure` |
| `GET /api/agg/<name>` | One aggregate: `hourly`, `busiest`, `stranded`, `electric`. `?side=auto\|local\|foreign` |
| `GET /api/exercises` | The lab's preset exercises |
| `GET /api/checks` | One pass/fail checkpoint per thing a module should have left behind |
| `POST /api/run` | `{sql, side}` — arbitrary SQL, read only. `side` is `local`, `foreign` or `both` |
| `GET /api/log` | The session ring buffer and its totals |

Every query response carries the SQL that ran, the elapsed time, the annotated
plan tree, and the verdict.

The tab is in the URL hash — `#over`, `#maps`, `#stats`, `#lab`, `#checks`,
`#log` — so a module can link straight at one.

## The lab

`POST /api/run` is what makes this an exercise rather than a demo. Two things
make it safe enough to hand to a room:

**The transaction is read only**, set on the connection before the first
statement. Postgres refusing the write is a far better guarantee than a keyword
blocklist would be — it covers the statements nobody thought to ban, and it
covers them inside CTEs and functions too. DDL never gets that far, because
`EXPLAIN` only accepts `SELECT` and the DML statements.

**`{S}` and `{L}` are substituted, not the schema name.** `{S}` is the schema
under test and `{L}` is always local, so one query text can be sent to both
sides in a single request and come back with two plans and two timings. That
comparison is the whole lesson; either side alone is just a number.

Results are capped at 500 rows on the way to the browser. The plan is the point.

## Checks

`GET /api/checks` runs each checkpoint **inside its own savepoint**. Without
that, the first failure aborts the transaction and every later check reports
"current transaction is aborted" instead of its own result — exactly backwards,
since the failing checks are the ones a reader opened the tab to see. Half of
them touch objects that legitimately do not exist yet (`cron.job` before module
03, `citibike_ingest` before the FDW), so failure is the normal case here.

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
- **No authentication, and the Lab runs SQL you send it.** The transaction is read only, but anyone who can reach the port can read your workshop data. Keep it on localhost.
- MapLibre GL JS loads from `unpkg.com` and needs WebGL. If either is unavailable — a proxy that blocks the CDN, a VM without WebGL — the Maps tab says so and every other tab is unaffected. That containment is deliberate: the `Map` constructor throwing used to take the rest of the page down with it.

## License

[MIT](../LICENSE). MapLibre GL JS is fetched at run time under its own licence
and is not vendored here.

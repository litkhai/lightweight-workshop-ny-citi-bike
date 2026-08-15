# 06 — Push the counting down

**[Previous](05-clickpipes.md) · [Workshop home](index.md) · [Next: The dashboard](07-dashboard.md)**

## Goal

Bring the ClickHouse tables back into the Postgres session as foreign tables,
then prove — from the plan, not the clock — that the counting runs remotely.

## Wire up pg_clickhouse

```bash
./scripts/psql.sh \
  -v ch_host="$(grep '^CH_HOST=' .env | cut -d= -f2)" \
  -v ch_db=ny_citibike -v ch_user=default \
  -v ch_pass="$(grep '^CH_PASSWORD=' .env | cut -d= -f2-)" \
  -f /sql/40-fdw-clickhouse.sql
```

Note `ch_db=ny_citibike` — the ClickHouse database, named to match the Postgres
schema since module 02. The script creates the extension, a foreign server, a
user mapping, and imports the two ClickHouse tables into a **local schema called
`ny_citibike_ch`**.

This is where the matched naming earns its keep:

```text
ny_citibike.station_status      the real table, in Postgres
ny_citibike_ch.station_status   the same rows, answered by ClickHouse
```

Same table name. Same columns. Same row count. **One prefix apart.** So when you
run the identical query text against each and the verdict changes, there is
nothing else it could have been — you did not touch the query, only which engine
was asked. That is the whole reason this workshop insists on one name per
namespace instead of `citibike` here and `default` there.

!!! note "Why `_ch` and not just `ny_citibike`"
    The foreign tables live in Postgres too, and the real schema already owns
    the bare name. `ny_citibike_ch` and `ny_citibike_ingest` from module 03 are
    both local Postgres schemas holding foreign tables — the suffix says "this is
    a window onto the other engine", which is the one distinction you actually
    want visible in a query.

!!! warning "The FDW dials outward from the Postgres server"
    Not from your laptop. A ClickHouse running in a container on your machine
    is unreachable from a managed Postgres in AWS — which is exactly why this
    workshop uses ClickHouse Cloud on both ends rather than a local container.

## The moment of truth

The script ends with two `EXPLAIN`s. Here is what to read.

### The working case

```sql
EXPLAIN (VERBOSE, COSTS OFF)
SELECT st.name, count(*), round(avg(ss.num_bikes_available), 1)
FROM ny_citibike_ch.station_status ss
JOIN ny_citibike_ch.stations st ON st.station_key = ss.station_key
GROUP BY st.name ORDER BY count(*) DESC LIMIT 10;
```

Look for a **Foreign Scan** whose `Remote SQL` contains the `GROUP BY` and the
aggregate functions. That means ClickHouse did the counting and sent back ten
rows.

### The counter-example

Same query, one word different — `ny_citibike.stations` instead of `ny_citibike_ch.stations`:

```sql
FROM ny_citibike_ch.station_status ss
JOIN ny_citibike.stations st ON st.station_key = ss.station_key
```

Now the `Remote SQL` selects **columns only**, and there is a `Hash Join` and a
`HashAggregate` above the foreign scan. Every row crossed the network to be
joined and counted in Postgres.

!!! danger "This is the failure mode to remember"
    Mixing one local table into a join collapses the pushdown. It does not
    error, it does not warn, and at small data volumes it does not even feel
    slow. It is why module 05 insisted on replicating both tables.

## Reading the verdict without reading the plan

```bash
./scripts/explain-pushdown.sh \
  "SELECT count(*) FROM ny_citibike_ch.station_status"

./scripts/explain-pushdown.sh \
  "SELECT st.name, count(*) FROM ny_citibike_ch.station_status ss
   JOIN ny_citibike.stations st ON st.station_key = ss.station_key GROUP BY st.name"
```

The script walks the plan and prints one of four verdicts:

| Verdict | What it means |
|---|---|
| **ClickHouse** | the remote SQL carries the aggregation |
| **Postgres — no foreign table in this plan** | it read local tables; that may be what you wanted |
| **Postgres — nothing to push down to** | no foreign tables are configured at all |
| **Postgres — the foreign scan selects columns only** | the pushdown failed; every row came back |

That third one exists for a reason. "There is no FDW here" and "the pushdown
failed" look identical if you only grep for the string `Remote SQL`, and
telling someone their query fell back when they never configured an FDW is
worse than saying nothing.

## Run the same file against both sides

```bash
./scripts/psql.sh -v s=ny_citibike    -f /sql/20-aggregate-pushdown.sql # local
./scripts/psql.sh -v s=ny_citibike_ch -f /sql/20-aggregate-pushdown.sql # ClickHouse
```

Identical SQL, one variable different. Compare the `Time:` lines that `\timing`
prints.

With a few hours of data the difference will be modest — both are fast at this
size, and you should be suspicious of anyone who shows you a dramatic number on
a small table. The plan is the evidence; the clock only becomes evidence once
the data is large.

## The query that hurts {: #the-query-that-hurts }

This is where snapshots-instead-of-events pays off as a teaching example.

To get departures and arrivals you have to diff consecutive snapshots per
station — a window function partitioned by station over the whole fact table:

```bash
./scripts/psql.sh -v s=ny_citibike -f /sql/30-snapshot-to-events.sql
```

The file ends with an `EXPLAIN (ANALYZE, BUFFERS)`. Read it before assuming
anything — because on this schema, the first thing it shows you is Postgres
doing well:

```text
WindowAgg  (actual rows=5018 loops=1)
  ->  Index Scan using status_station_time_ix on station_status
```

**No sort at all.** The index created in module 02 is
`(station_key, polled_at)`, which is exactly the ordering
`PARTITION BY station_key ORDER BY polled_at` needs, so the window function
reads straight down the index.

That is worth sitting with, because it is the opposite of the lesson people
expect here. With the right index, Postgres is good at this. The argument for
moving work is not "Postgres is slow at window functions" — it is narrower and
more honest:

**You can index for one access path. You cannot index for all of them.** Change
the partition to hour-of-day, or the ordering to bikes-available, or add a
second window over a different key, and the index stops covering it — then you
get the sort, and at a few million rows you get it on disk. ClickHouse's
storage order does the same job for the one ordering you chose, but its column
layout and vectorised execution mean the *uncovered* shapes degrade far more
gently.

Try it. Add `ORDER BY num_bikes_available` to the window and re-run the
`EXPLAIN`; watch `Sort Method` appear.

```bash
./scripts/psql.sh -v s=ny_citibike_ch -f /sql/30-snapshot-to-events.sql
```

!!! note "Measured, and at what size"
    The plan above was taken at 5,018 rows on a local PostGIS 17 container —
    small. What it establishes is the *shape* of the plan, not a performance
    claim. Row counts and timings on your own service, after your own
    collection window, are the only ones worth quoting.

!!! note "Window functions may not push down"
    Aggregate pushdown and window-function pushdown are different features, and
    a wrapper can support the first without the second. Run
    `explain-pushdown.sh` on the window query and believe what it says. If it
    reports `dragged`, the honest conclusion is that this particular shape
    needs to be run *on* ClickHouse rather than *through* Postgres — which is a
    perfectly good finding, and a more useful one than pretending otherwise.

## Point the dashboard at the foreign schema

Add this to `.env`:

```bash
FOREIGN_SCHEMA=ny_citibike_ch
```

## Next

[07 — The dashboard](07-dashboard.md)

# 05 — Push the counting down

**[Previous](04-clickpipes.md) · [Workshop home](index.md) · [Next: The dashboard](06-dashboard.md)**

## Goal

Bring the ClickHouse tables back into the Postgres session as foreign tables,
then prove — from the plan, not the clock — that the counting runs remotely.

## Wire up pg_clickhouse

```bash
./scripts/psql.sh \
  -v ch_host="$(grep '^CH_HOST=' .env | cut -d= -f2)" \
  -v ch_db=default -v ch_user=default \
  -v ch_pass="$(grep '^CH_PASSWORD=' .env | cut -d= -f2-)" \
  -f /sql/40-fdw-clickhouse.sql
```

That creates the extension, a foreign server, a user mapping, and imports the
two ClickHouse tables into a **separate schema called `ch`**.

Keeping the namespaces apart is what makes the rest legible:

```text
bike.station_status   local Postgres
ch.station_status     the same data, on ClickHouse
```

The same query text against either one tells you where the work went.

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
FROM ch.station_status ss
JOIN ch.stations st ON st.station_key = ss.station_key
GROUP BY st.name ORDER BY count(*) DESC LIMIT 10;
```

Look for a **Foreign Scan** whose `Remote SQL` contains the `GROUP BY` and the
aggregate functions. That means ClickHouse did the counting and sent back ten
rows.

### The counter-example

Same query, one word different — `bike.stations` instead of `ch.stations`:

```sql
FROM ch.station_status ss
JOIN bike.stations st ON st.station_key = ss.station_key
```

Now the `Remote SQL` selects **columns only**, and there is a `Hash Join` and a
`HashAggregate` above the foreign scan. Every row crossed the network to be
joined and counted in Postgres.

!!! danger "This is the failure mode to remember"
    Mixing one local table into a join collapses the pushdown. It does not
    error, it does not warn, and at small data volumes it does not even feel
    slow. It is why module 04 insisted on replicating both tables.

## Reading the verdict without reading the plan

```bash
./scripts/explain-pushdown.sh \
  "SELECT count(*) FROM ch.station_status"

./scripts/explain-pushdown.sh \
  "SELECT st.name, count(*) FROM ch.station_status ss
   JOIN bike.stations st ON st.station_key = ss.station_key GROUP BY st.name"
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
./scripts/psql.sh -v s=bike -f /sql/20-aggregate-pushdown.sql   # local
./scripts/psql.sh -v s=ch   -f /sql/20-aggregate-pushdown.sql   # ClickHouse
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
./scripts/psql.sh -v s=bike -f /sql/30-snapshot-to-events.sql
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
./scripts/psql.sh -v s=ch -f /sql/30-snapshot-to-events.sql
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
FOREIGN_SCHEMA=ch
```

## Next

[06 — The dashboard](06-dashboard.md)

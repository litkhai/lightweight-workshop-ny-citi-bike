# Workshop overview

## Who this is for

Anyone evaluating whether an operational Postgres and an analytical ClickHouse
can share one workload without turning into two disconnected systems. You
should be comfortable with SQL and a terminal. You do not need to know PostGIS
or ClickHouse beforehand — both are introduced through the one problem this
dataset poses.

## The shape of the problem

Citi Bike gives you two datasets with completely different physics:

| | What it is | Size | Changes | Wants |
|---|---|---|---|---|
| **Stations** | dock locations, capacity, names | ~2,500 rows | rarely | spatial indexes, geometry types |
| **Status** | bikes and docks free, per station, per minute | +3.6M rows/day | constantly | column storage, fast aggregation |

Putting both in one engine means one of them is badly served. Putting them in
two engines usually means an ETL job, a copy that goes stale, and two query
languages.

The third option is what this workshop builds: both tables replicated to
ClickHouse, `pg_clickhouse` bringing them back into the Postgres session as
foreign tables, and the query planner deciding what runs where. The join key is
a `bigint`, so no geometry ever has to cross.

## The names, up front {: #names }

**There are two.** Every object in this workshop lives under one of them.

| Name | Where it lives | What is in it |
|---|---|---|
| `ny_citibike` | Postgres **schema** *and* ClickHouse **database** | the real tables, on both engines |
| `ny_citibike_ch` | Postgres schema | foreign tables — ClickHouse, seen from inside Postgres |

### Why the first name is used twice

Postgres calls a namespace a schema and ClickHouse calls it a database, but they
are the same idea, so they get the same name. A table then has the **same
qualified name wherever it lives**:

```text
ny_citibike.station_status      in Postgres   … and in ClickHouse
```

That is not tidiness. In [module 06](06-pushdown.md) you send one query text to
both engines, and the only thing that differs is a schema prefix. If the names had
drifted — `citibike` here, `default` there — a changed result could always have
been a different table rather than a different engine.

### Why the second name exists at all

The foreign tables live in Postgres too, and the real schema already owns the bare
name; two schemas cannot share one. So they take a suffix, and the pairing reads:

```text
ny_citibike.station_status      the real table
ny_citibike_ch.station_status   the same rows, fetched from ClickHouse
```

`_ch` is the only suffix in the workshop. It marks **a window onto the other
engine**, which is the one distinction you want visible in a query.

Every table on both engines, what writes it and what it joins to, is laid out in
the [data model reference](data-model.md).

### One server, four foreign tables

`ny_citibike_ch` is filled in twice, by the two modules that need it, over a
single foreign server:

| Foreign table | Imported by | Points at |
|---|---|---|
| `gbfs_status`, `gbfs_stations` | module 03 | the landing tables `url()` writes |
| `stations`, `station_status` | module 06 | the CDC mirror ClickPipes writes |
| `sim_trips` | module 06, if you ran [09](09-trips.md) | the generated trip table |

There used to be a second server and a third schema — `ny_citibike_ingest_svr`
and `ny_citibike_ingest` — on the theory that ingestion and measurement deserved
separate plumbing. Once both sides were named `ny_citibike` they were pointing at
the same database over two protocols, and one server reads both sets perfectly
well. The second one bought nothing and cost a duplicate copy of the ClickHouse
password and a third name to explain.

!!! note "Renaming the workshop"
    Everything above is derived from one string. To use a different name, change
    `LOCAL_SCHEMA` in `.env`, the `CREATE SCHEMA` in `sql/01-schema.sql`, the
    `CREATE DATABASE` in `clickhouse/01-ingest-rmv.sql`, and keep the `_ch`
    suffix consistent. The workshop does not template it, because a schema name
    interpolated into a hundred places is harder to read than a name you can
    grep.

## Modules

| | Module | Time | Needs |
|---|---|---|---|
| 00 | [Prerequisites](00-prerequisites.md) | 10 min | Docker |
| 01 | [Provision the two services](01-provision.md) | 20 min | **console** · a ClickHouse Cloud account |
| 02 | [Postgres, PostGIS and the schema](02-postgres-and-feed.md) | 10 min | module 01 |
| 03 | [The feed, with nothing on your laptop](03-the-feed.md) | 20 min | module 02 |
| 04 | [The half that cannot move](04-spatial.md) | 15 min | ~10 min of collected data |
| 05 | [Replicate to ClickHouse](05-clickpipes.md) | 20 min | **console** · module 03 |
| 06 | [Push the counting down](06-pushdown.md) | 25 min | module 05 |
| 07 | [The dashboard](07-dashboard.md) | 15 min | module 06 |
| 08 | [Wrap-up and teardown](08-wrap-up.md) | 10 min | — |

About **2 hours** of hands-on time. Modules 01 and 05 involve the console and
cannot be rushed; the rest is copy-paste.

Data volume grows while you work. By module 06 you will have tens of thousands
of rows — enough to see the plans differ, not enough to see Postgres struggle.
That is why every verdict in this workshop is read from the plan: at this size
the clock cannot tell you anything.

Two ways to get timings that do mean something. Leave the pg_cron job running
overnight and come back to 3.6M rows. Or run the optional
[module 09](09-trips.md), whose generated trip table reaches ten million rows in
a quarter of an hour. Measured there: the same aggregate text takes **10.4 s**
against the local schema and **0.47 s** against the foreign one — 22x, on one
changed prefix. That is the point at which the badge and the stopwatch finally
agree, and it is worth reaching if you have the fifteen minutes.

## What you will be able to say afterwards

- Which specific operations cannot leave Postgres, and why the geometry type is the reason
- What a pushed-down aggregate looks like in `EXPLAIN`, and what a failed one looks like
- The single most common way a working pushdown quietly stops working
- What logical replication needs from a Postgres table before ClickPipes will accept it
- Why a fast query is not evidence that anything was pushed down

## Ground rules for the numbers

Every claim in these pages that has a number attached was measured against a
running system, and the pages say which. Where a number depends on your own
service size or how long you have been collecting, the page says that instead
of quoting one.

The exception is the console walkthroughs in modules 01 and 05: cloud consoles
change their wording faster than documentation can follow, so those modules
describe **what you are looking for** alongside the current labels. If a button
has been renamed, the surrounding paragraph should still get you there.

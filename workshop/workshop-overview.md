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

## The names, up front

Everything lives under one namespace name, spelled the same on both engines:

| | Where | What |
|---|---|---|
| `ny_citibike` | Postgres **schema** | the real tables. Geometry lives here |
| `ny_citibike` | ClickHouse **database** | landing tables, plus the CDC mirror |
| `ny_citibike_ingest` | Postgres schema | foreign tables over ClickHouse's landing tables |
| `ny_citibike_ch` | Postgres schema | foreign tables over ClickHouse's mirror |

The first two share a name deliberately. `ny_citibike.station_status` refers to
the same data whichever engine you ask, so the only difference between a local
query and a pushed-down one is a prefix — and when the verdict changes you know
the query text did not. The two suffixed schemas are both local, and the suffix
is there because the real schema already owns the bare name.

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
a quarter of an hour — where the same aggregate takes 12 seconds locally against
0.17 for the small one, and the badge and the stopwatch finally agree.

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

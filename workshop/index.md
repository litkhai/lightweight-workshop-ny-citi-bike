# NY Citi Bike — PostGIS meets ClickHouse

A self-service workshop built on a data feed that is **actually live**. No
sample dump, no synthetic generator: New York's Citi Bike publishes the state
of every dock as public JSON, and by the end of the first module your database
is filling up with it in real time.

## The claim you are going to test

> You do not have to choose between Postgres and ClickHouse. Keep the geography
> in Postgres, send only the counting to ClickHouse, and neither engine does
> the thing it is bad at.

That is easy to say and easy to fake. A dashboard that shows numbers cannot
tell you which engine produced them, and "it felt fast" is not evidence — a
foreign table will happily drag millions of rows across the network and count
them locally. So every query in this workshop ends with a verdict read out of
the **execution plan**, not out of a stopwatch.

## What you will build

```text
Citi Bike GBFS            public JSON, no API key, ~2,500 stations, refreshed every 60s
      │  ClickHouse refreshable MV over url(), every minute
      ▼
ClickHouse Cloud          database ny_citibike
      gbfs_status                                  ← landing
      │  ny_citibike_ingest.gbfs_status  +  pg_cron, every minute
      ▼
ClickHouse Managed Postgres   schema ny_citibike
      stations              PostGIS points  · 2,500 rows  · barely changes
      station_status        snapshots       · +3.6M rows/day · only ever counted
      │  ClickPipes (Postgres CDC)
      ▼
ClickHouse Cloud          database ny_citibike
      stations · station_status                    ← mirrored, name for name
      ▲
      │  ny_citibike_ch.*  — foreign tables, back in the Postgres session
      │
Your SQL: geometry stays local, aggregates run remotely
      │
      ▼
Dashboard (Docker) — badges every query with the engine that answered
```

## Start here

New participants begin with [Prerequisites](00-prerequisites.md) and work
through in order. Each module states what it needs from the previous one, so
you can stop and resume.

Instructors delivering this to a room should read the
[Instructor Guide](instructor-guide.md) first — it covers the timings that slip
and the two steps that cannot be rushed.

## Honest scope

Three of the steps in this workshop **cannot be scripted**, and this is by
design rather than laziness: creating cloud services and connecting a ClickPipe
are console actions tied to your own account and billing, and the refreshable
materialized views that fetch the feed are ClickHouse statements that do not go
through `psql`. Those modules are written as click-through walkthroughs.

Everything else — schema, ingestion, queries, dashboard — runs from this
repository with Docker and nothing else installed.

!!! warning "This costs money"
    Two paid cloud services run for the duration. Both are small, and the
    workshop uses trial-sized instances, but they are not free. Module
    [08 — Wrap-up](08-wrap-up.md) has the teardown, and you should read the
    cost note there **before** you start rather than after.

    Note especially that **closing your laptop does not stop collection.** Both
    schedulers are server-side; that is the point of the design and also its
    one trap.

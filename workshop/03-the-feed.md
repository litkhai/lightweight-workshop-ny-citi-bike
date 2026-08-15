# 03 — The feed, with nothing on your laptop

**[Previous](02-postgres-and-feed.md) · [Workshop home](index.md) · [Next: The half that cannot move](04-spatial.md)**

## Goal

Get live data arriving continuously, with no process running on your machine.
Set it up once, close the laptop, come back tomorrow to a day of data.

## The problem this module solves

You need to pull a JSON file over HTTPS every minute and land it in Postgres.
The obvious answer is a small script somewhere. The interesting question is
whether the databases can do it themselves — and the answer turns out to be
**half yes**, in a way that teaches you something about both engines.

### Postgres cannot fetch it. Here is exactly why.

ClickHouse Managed Postgres publishes around 145 extensions, and **none of them
is an HTTP client**:

| | |
|---|---|
| `http` (pgsql-http) | not in the catalogue |
| `pg_net` | not in the catalogue |
| `plpython3u` | not in the catalogue |
| `plperlu` | **present**, and installs cleanly |

So `plperlu` looks like the way out — untrusted PL/Perl may open a socket, and
`HTTP::Tiny` is core Perl. `CREATE EXTENSION plperlu` succeeds. Then every
fetch dies:

```text
IO::Socket::SSL 1.42 must be installed for https support
Net::SSLeay 1.49 must be installed for https support
```

The server's Perl has no TLS stack. Confirm it on your own service:

```bash
./scripts/psql.sh -f /sql/03-check-in-db-http.sql
```

```text
 item            | value
-----------------+----------------------------------------------
 perl version    | 5.034000
 modules found   | IO::Socket::INET
   IO::Socket::SSL | MISSING
   Net::SSLeay     | MISSING
 CA bundle       | /etc/ssl/certs/ca-certificates.crt
 verdict         | https from inside Postgres is NOT possible on this host
```

Note the last two lines together. The **certificates are there**; it is the
Perl build that has no TLS. That means the blocker is the image rather than a
permission, and a future platform update could flip it without an announcement
— which is why this check ships as a file rather than a sentence.

### ClickHouse can fetch it, and can schedule itself

ClickHouse has [`url()`](https://clickhouse.com/docs/sql-reference/table-functions/url)
as a first-class table function, and **refreshable materialized views** give it
a scheduler. Put those together and the feed arrives with nothing running
locally.

## Step 1 — ClickHouse pulls

Open your ClickHouse service's SQL console and run
[`clickhouse/01-ingest-rmv.sql`](https://github.com/litkhai/lightweight-workshop-ny-citi-bike/blob/main/clickhouse/01-ingest-rmv.sql).
These are ClickHouse statements — they do not go through `psql`.

The heart of it:

```sql
CREATE MATERIALIZED VIEW citibike.gbfs_pull
REFRESH EVERY 1 MINUTE APPEND
TO citibike.gbfs_status
AS
WITH src AS (
    SELECT json FROM url('https://gbfs.lyft.com/…/station_status.json',
                         'JSONAsString', $$json String$$)
)
SELECT toDateTime(JSONExtractUInt(json,'last_updated')) AS polled_at,
       JSONExtractString(s,'station_id')                AS station_id,
       …
FROM src
ARRAY JOIN JSONExtractArrayRaw(JSONExtractRaw(json,'data'),'stations') AS s;
```

### What to understand about a refreshable MV

An ordinary ClickHouse materialized view is a **trigger**: it fires when rows
are inserted into a source table. That is no use here, because nothing is
inserting — the data is sitting on a web server.

A **refreshable** materialized view is the other model. It re-runs its whole
`SELECT` on a wall-clock schedule, which is exactly what polling is.

**`APPEND` is the word that matters.** Without it, each refresh *replaces* the
target table's contents. That is correct for a rollup and catastrophic for a
feed you are accumulating — you would be left holding only the newest snapshot,
and you would probably not notice for a while. With `APPEND`, each run adds its
rows.

The station list uses the other form deliberately:

```sql
CREATE MATERIALIZED VIEW citibike.gbfs_stations_pull
REFRESH EVERY 1 HOUR              -- no APPEND: replace
TO citibike.gbfs_stations
```

Stations are a dimension. The newest list is the truth; keeping an hourly copy
of it forever would be waste.

### Two things to watch

```sql
SELECT view, status, last_success_time, next_refresh_time, exception
FROM system.view_refreshes WHERE database = 'citibike';
```

`exception` is where a failed fetch shows up. A refreshable MV that cannot
reach its URL does not raise anything at you — it just quietly keeps its last
result and sets `exception`.

And **duplicate snapshots are handled differently here than in Postgres.** The
publisher refreshes on its own ~60s clock, so a minute-by-minute pull sometimes
re-reads a file it already has. ClickHouse deals with that structurally:
`ReplacingMergeTree ORDER BY (polled_at, station_id)` collapses the repeat at
merge time. No comparison, no bookkeeping — the storage engine absorbs it.

## Step 2 — Postgres pulls from ClickHouse

```bash
./scripts/psql.sh \
  -v ch_host="$(grep '^CH_HOST=' .env | cut -d= -f2)" \
  -v ch_pass="$(grep '^CH_PASSWORD=' .env | cut -d= -f2-)" \
  -f /sql/03-postgres-sync.sql
```

Two things happen. `pg_clickhouse` imports the landing tables as foreign
tables, and `pg_cron` schedules a procedure that copies new snapshots forward:

```sql
SELECT coalesce(max(polled_at), '1970-01-01') INTO hwm
  FROM citibike.station_status;

INSERT INTO citibike.station_status (…)
SELECT … FROM citibike_ingest.gbfs_status g
JOIN citibike.stations st ON st.station_id = g.station_id
WHERE g.polled_at > hwm;
```

A **high-water mark**, not a "since last run" timestamp. If a run is missed —
the scheduler was busy, the FDW timed out — the next one closes the gap. A
"last run" cursor leaves a hole that nothing ever comes back for.

```sql
SELECT cron.schedule('citibike-sync', '* * * * *',
                     'CALL citibike.sync_from_clickhouse()');
```

## The shape you just built

```text
Citi Bike GBFS
     │  https
     ▼
ClickHouse Cloud          refreshable MV, every minute
     citibike.gbfs_status         ← landing
     │
     │  pg_clickhouse foreign table
     ▼
Managed Postgres          pg_cron, every minute
     citibike.stations            ← PostGIS geometry
     citibike.station_status      ← the fact table
     │
     │  ClickPipes CDC            ← module 05
     ▼
ClickHouse Cloud
     citibike.station_status      ← what the pushdown reads
```

**Two schedulers, both server-side, nothing on your laptop.**

### The obvious objection

The data reaches ClickHouse, goes to Postgres, and then goes back to ClickHouse
again. That is real, and it is worth saying out loud rather than hoping nobody
notices.

It is a fair trade for three reasons:

1. **The landing table and the fact table are different things.** One is how
   bytes arrive; the other is the operational table this workshop is about.
   They happen to share a cloud.
2. **The subject is the split, not the ingestion.** Modules 05 and 06 are about
   what happens between an operational Postgres and an analytical ClickHouse.
   How rows got into Postgres in the first place is a side quest — and in a
   real system it would be an application writing them.
3. **It removes the last laptop dependency.** Which is the whole point.

If you would rather not have the round trip, the alternative is to skip
ClickPipes and query the landing table directly. You then lose the CDC and
pushdown lessons, which are the two most transferable things here.

## Verify

```bash
./scripts/psql.sh -f /sql/02-verify.sql
```

Wait two or three minutes and run it again. `rows` and `snapshots` should both
have moved, with nothing running on your machine.

```text
 rows  | snapshots |  first   |   last   | seconds_behind
-------+-----------+----------+----------+----------------
 22581 |         9 | 15:17:28 | 15:30:28 |            114
```

About two minutes behind is normal and is the sum of the two schedules: up to
a minute waiting for ClickHouse to refresh, up to another for pg_cron to pull.
Tighten either one if you care, though the feed itself only moves every 60
seconds.

!!! warning "This keeps running after you close the laptop"
    That is the feature, and it is also the trap. At 3.6M rows a day it will
    keep accumulating — and paying — until you unschedule it. Both stop
    commands are in [module 08](08-wrap-up.md), and it is worth reading them
    now rather than at the end.

## If you would rather use a container

`collector/` in the repository does the same job from a Docker container in
about 200 lines of Python. It is a legitimate choice — simpler to reason about,
no ClickHouse dependency for ingestion, and it is what you would reach for if
your Postgres were somewhere with an HTTP extension available.

It is not the default here because it needs a machine that stays awake.

## Next

[04 — The half that cannot move](04-spatial.md)

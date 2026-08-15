# 02 — Postgres, PostGIS and the live feed

**[Previous](01-provision.md) · [Workshop home](index.md) · [Next: The half that cannot move](03-spatial.md)**

## Goal

Create the schema, then have **the database itself** start pulling the feed —
no container, no process on your laptop.

## Create the schema

```bash
./scripts/psql.sh -f /sql/01-schema.sql
```

`psql` runs in a container with `sql/` mounted at `/sql`, which is why every
path in this workshop starts `/sql/`. Nothing was installed on your machine.

### What that file just did, and why

Two tables. The split between them is the entire workshop.

```sql
bike.stations        station_key bigint PK, …, geom geometry(Point,4326)
bike.station_status  status_id bigint PK, station_key bigint, polled_at, counts…
```

Four decisions in there are worth understanding, because each is a thing that
bites people later.

**The surrogate `station_key`.** GBFS publishes `station_id` as a *string* —
Citi Bike's look like `"2124037125711300644"`, and other systems use
non-numeric ids entirely. The join key is the one value that crosses to the
aggregating side on every row, so it gets to be a `bigint`. This is also what
lets the geometry stay behind: the counting side never needs to know what a
point is.

**A primary key on the fact table.** Logical replication needs a replica
identity. Without a primary key ClickPipes refuses the table outright:
*"cannot be replicated because they don't have a valid replica identity"*.

**No foreign key from status to stations.** A station can appear in
`station_status.json` before `station_information.json` catches up. A
constraint here would reject real observations.

**A named publication, not `FOR ALL TABLES`.** A `FOR ALL TABLES` publication
sweeps up every scratch table anyone creates while poking at the workshop.

## Start collecting

```bash
./scripts/psql.sh -f /sql/03-collector-in-db.sql
```

```text
NOTICE:  station_information: https://gbfs.lyft.com/gbfs/2.3/bkn/en/station_information.json
NOTICE:  station_status:      https://gbfs.lyft.com/gbfs/2.3/bkn/en/station_status.json
NOTICE:  stations: 2509 upserted, 2509 known
NOTICE:  collected 2509 rows for 2026-08-15 15:02:28+00

== the collector is now the database ==
 jobid |   jobname    | schedule  | active
-------+--------------+-----------+--------
     1 | gbfs-collect | * * * * * | t
```

That is the whole collector. **Close your terminal and it keeps running** —
the schedule lives in the database, not on your laptop.

Notice the first two lines. The registry says `gbfs.citibikenyc.com`; the files
are actually served from `gbfs.lyft.com`. The procedure followed the discovery
chain rather than trusting a hardcoded URL, which is the only thing that
survives an operator moving their CDN.

## What is actually running

Four objects, each doing one thing:

| | |
|---|---|
| `bike.http_get(url)` | **plperlu.** One HTTPS GET. Transport only |
| `bike.discover()` | resolves the discovery document to feed URLs, stores them in `bike.feed` |
| `bike.load_stations()` | `station_information` → `bike.stations`, building `geom` |
| `bike.collect()` | `station_status` → `bike.station_status`, skipping repeats |
| `cron.schedule(…)` | calls `bike.collect()` every minute |

### Why plperlu, of all things

ClickHouse Managed Postgres ships a large extension catalogue — 145 or so —
and **none of them is an HTTP client.** No `http` (pgsql-http), no `pg_net`, no
`plpython3u`. What it does have is `plperlu`, the untrusted PL/Perl language,
and untrusted means the function may open a socket.

So `bike.http_get()` is nine lines of Perl that do exactly one thing, and every
other step is ordinary PL/pgSQL working on `jsonb`. That division is
deliberate: an untrusted language runs as the operating-system user Postgres
runs as, so the less that lives inside it, the better. Parsing belongs to
Postgres, which is good at it.

!!! warning "Two things can stop this working, and both are quick to check"
    **`CREATE EXTENSION plperlu` needs superuser.** Having the extension in the
    catalogue is not the same as being allowed to install it.
    `./scripts/preflight.sh` reports both facts separately.

    **Perl needs to find a CA bundle.** `HTTP::Tiny` looks for the `Mozilla::CA`
    CPAN module, not for the operating system's certificate store, and without
    one it fails with *"Couldn't find a CA bundle"* — which reads like a network
    fault and is not one. `bike.http_get()` locates the system bundle itself
    and raises a clear error if there is none.

    If plperlu is refused on your service, `collector/` in the repository is a
    container that does the same job from outside. It is a fallback, not the
    lesson.

## Verify

Give it five minutes, then:

```bash
./scripts/psql.sh -f /sql/02-verify.sql
```

```text
== the collector, which is the database itself ==
   jobname    | schedule  | active | last_run  | failures
--------------+-----------+--------+-----------+----------
 gbfs-collect | * * * * * | t      | succeeded |        0

 last_poll | last_poll_result
-----------+-----------------------
 15:04:00  | 2509 rows at 15:03:28
```

If `bikes_out_there` further down is changing between polls, you have a live
system. That number is people actually riding.

### Watching the scheduler

```sql
SELECT runid, status, start_time::time, return_message
FROM cron.job_run_details ORDER BY runid DESC LIMIT 5;
```

pg_cron will not run two copies of a job at once, so a slow fetch delays the
next tick rather than stacking on top of it.

## The arithmetic you are now committed to

```text
2,509 stations × 1 snapshot/minute × 1,440 minutes = 3.6M rows/day
```

You will pass 24M rows in about a week. You need nowhere near that to finish —
a few hours is plenty to see the plans differ.

## Polling faster does nothing

The feed's `ttl` is 60 seconds and `station_status.json` carries its own
`last_updated`. `bike.collect()` compares that stamp against the last one it
stored and returns immediately when nothing has changed.

That is not tidiness. Storing the same snapshot twice would give those stations
double weight in every average over the fact table. A real run under pg_cron:

```text
 runid |  status   |  started  
-------+-----------+-----------
     1 | succeeded | 15:03:00     -- feed still at 15:02:28, nothing written
     2 | succeeded | 15:04:00     -- feed moved to 15:03:28, 2509 rows
```

Three polls, two stored snapshots.

## A snapshot is not an event

GBFS gives you a **level** — "this dock holds 7 bikes right now" — not a
change. Departures and arrivals have to be derived by diffing consecutive
snapshots per station. You will do that in
[module 05](05-pushdown.md#the-query-that-hurts).

## Changing city

The feed URL is a row in the database, not a config file:

```sql
UPDATE bike.feed SET discovery_url =
  'https://gbfs.lyft.com/gbfs/2.3/dca-cabi/gbfs.json' WHERE id = 1;
CALL bike.discover();
CALL bike.load_stations();
```

## Next

[03 — The half that cannot move](03-spatial.md)

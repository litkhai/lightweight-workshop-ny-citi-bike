# 08 — Wrap-up and teardown

**[Previous](07-dashboard.md) · [Workshop home](index.md)**

## What you proved

Not "ClickHouse is fast". Something more specific and more useful:

**Geometry has a reason to stay put.** `geometry(Point, 4326)`, GiST indexes
and the `ST_*` functions are PostGIS's, and there is nothing on the other side
to translate them into. That is not a limitation to work around — the geometry
is 2,500 rows that change weekly.

**Counting has a reason to move.** 3.6M rows a day, read in full, returning a
screenful. The best possible ratio for sending work somewhere else.

**A `bigint` join key is what makes the split possible.** Because
`station_key` is an integer, the aggregating side never needs to know what a
point is.

**Both tables have to be replicated.** One local table in a join collapses the
pushdown, silently, with no error and no warning.

**Neither database could do the whole job alone.** Postgres has no way to
fetch an https URL — no HTTP extension, and a Perl build with no TLS.
ClickHouse has `url()` and a scheduler but no geometry type. The pipeline works
because each engine does the part it can.

**A fast query is not evidence.** The only honest answer to "did this push
down?" is in the plan. You now have four ways to read it: `EXPLAIN` directly,
`scripts/explain-pushdown.sh`, the dashboard badge, and the dashboard's Lab tab
running one query against both engines at once.

## Teardown — read this part

Two paid services are running and the database is still collecting every minute.

### 1. Stop both schedulers

There are **two**, and neither is on your laptop. `docker compose down` stops
the dashboard and nothing else.

On Postgres:

```bash
./scripts/psql.sh -c "SELECT cron.unschedule('ny_citibike-sync')"
```

On ClickHouse — in its SQL console:

```sql
DROP VIEW IF EXISTS ny_citibike.gbfs_pull;
DROP VIEW IF EXISTS ny_citibike.gbfs_stations_pull;
```

Then confirm both are gone:

```bash
./scripts/psql.sh -c "SELECT jobname FROM cron.job"
```

```sql
SELECT view, status FROM system.view_refreshes WHERE database = 'ny_citibike';
```

Finally, the dashboard:

```bash
docker compose down
```

### 2. Delete the ClickPipe — before anything else

In the ClickHouse console, open the pipe and **delete** it (not pause).

Then confirm from Postgres that the slot actually went away:

```bash
./scripts/psql.sh -c "SELECT slot_name, active FROM pg_replication_slots"
```

!!! danger "An orphaned slot will fill the disk"
    An inactive replication slot retains WAL **indefinitely**, waiting for a
    consumer that is never coming back. If a slot is still listed after
    deleting the pipe, drop it by hand:

    ```sql
    SELECT pg_drop_replication_slot('slot_name_here');
    ```

    This is the single most common way a Postgres CDC setup takes down a
    database, and it happens after the demo is over, when nobody is looking.

### 3. Delete both services

In the console, delete `citibike-analytics` and `citibike-oltp`.

Deleting the services is what stops the billing. Stopping the containers does
not, and neither does deleting the pipe.

### 4. Check

Go back to the services list and confirm both are gone. Then check your
organization's usage page — a service you thought you deleted but only paused
is the other way this gets expensive.

## Cost, honestly

This workshop runs two small managed services for about two hours. On trial
credit that is comfortably free. On a paid account it is small but not zero,
and the variable that actually matters is **how long you leave the two
schedulers running afterwards.** Closing your laptop does not stop either of
them — that is the point of a server-side pipeline, and also its one trap. At
3.6M rows a day the ClickHouse landing table and the Postgres fact table both
grow steadily, and every fact row replicates back a third time through
ClickPipes.

If you want to leave it running to get to the interesting data volumes, that is
a legitimate choice. Just make it deliberately, and set a calendar reminder to
tear it down.

## Where to go next

**Make the pushdown fail on purpose.** Exercises 3 and 4 in the dashboard's Lab
tab do exactly this, and exercise 7 is a blank page for your own. Understanding
the failure mode is worth more than seeing the success case twice.

**Try a different city.** Point the two `url()` calls in
`clickhouse/01-ingest-rmv.sql` at another system from
[the registry](https://github.com/MobilityData/gbfs/blob/master/systems.csv) and
re-run the file. Everything else works unchanged — the map re-centres itself
from the data.

**Leave it running for a week.** At 24M rows the timings in module 06 stop
being academic, and the un-indexed variants of the window query start sorting
on disk where the covered one does not.

**Compare against the trip-based version.** The
[PostGIS + Seoul bike lab](https://github.com/litkhai/clickhouse-hols/tree/main/managed-postgres/postgis-fdw-bike)
does the same split with real trip events instead of derived snapshots.

## Feedback

Issues and pull requests welcome at
[litkhai/lightweight-workshop-ny-citi-bike](https://github.com/litkhai/lightweight-workshop-ny-citi-bike).

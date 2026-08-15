# 02 — Postgres, PostGIS and the live feed

**[Previous](01-provision.md) · [Workshop home](index.md) · [Next: The half that cannot move](03-spatial.md)**

## Goal

Create the schema, start the collector, and watch real data arrive.

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

Four decisions in there are worth understanding before you move on, because
each one is a thing that bites people later.

**The surrogate `station_key`.** GBFS publishes `station_id` as a *string* —
Citi Bike's look like `"2124037125711300644"`, and other systems use
non-numeric ids entirely. The join key is the one value that crosses to the
aggregating side on every single row, so it gets to be a `bigint`. This is also
what lets the geometry stay behind: the counting side never needs to know what
a point is.

**A primary key on the fact table.** Logical replication needs a replica
identity. Without a primary key ClickPipes refuses the table outright:
*"cannot be replicated because they don't have a valid replica identity"*.
`REPLICA IDENTITY FULL` would also satisfy it, but a `bigint` key is what
ClickHouse wants to order and deduplicate on anyway.

**No foreign key from status to stations.** A station can appear in
`station_status.json` before `station_information.json` catches up, and
stations get retired between the two files. A constraint here would reject real
observations. The collector inserts the station first when it meets an unknown
id — best-effort by design.

**A named publication, not `FOR ALL TABLES`.**

```sql
CREATE PUBLICATION bike_pub FOR TABLE bike.stations, bike.station_status;
```

A `FOR ALL TABLES` publication sweeps up every scratch table anyone creates
while poking at the workshop, and each one then has to be dealt with
downstream.

## Start collecting

```bash
docker compose up -d --build collector
docker compose logs -f collector
```

You should see discovery resolve, the dimension load, then a poll every minute:

```text
14:22:01 discovering https://gbfs.citibikenyc.com/gbfs/2.3/gbfs.json
14:22:01   station_information  https://gbfs.lyft.com/gbfs/2.3/bkn/en/station_information.json
14:22:01   station_status       https://gbfs.lyft.com/gbfs/2.3/bkn/en/station_status.json
14:22:03 stations: 2509 in feed, 2509 known
14:22:04 poll 1: 2509 rows, 2509 total
14:23:05 poll 2: 2509 rows, 5018 total
```

Notice the second and third lines. The registry says `gbfs.citibikenyc.com`;
the actual files are served from `gbfs.lyft.com`. The collector followed the
discovery chain rather than trusting a hardcoded URL, which is the only way
this keeps working when an operator moves their CDN.

Leave it running. Press `Ctrl-C` to stop watching the logs — the container
keeps going.

## Verify

Give it five minutes, then:

```bash
./scripts/psql.sh -f /sql/02-verify.sql
```

The sections that should have content now are **stations**, **status**, and
**is the feed still moving?**. Replication and foreign tables are empty — those
are modules 04 and 05.

```text
== is the feed still moving? (last 10 polls) ==
  poll   | stations | bikes_out_there | free_docks
 14:27:04|     2509 |           12843 |      41902
 14:26:03|     2509 |           12866 |      41880
```

If `bikes_out_there` is changing between polls, you have a live system. That
number is people actually riding.

## The arithmetic you are now committed to

```text
2,509 stations × 1 poll/minute × 1,440 minutes = 3.6M rows/day
```

At the default 60-second interval you will pass 24M rows in about a week. You
do not need anywhere near that to finish the workshop — a few hours is plenty
to see the plans differ — but it is worth knowing what the tap is set to.

!!! note "Why not poll faster?"
    The feed's own `ttl` is 60 seconds and `station_status.json` carries a
    `last_updated` timestamp. Poll every 15 seconds and three cycles out of
    four fetch a file you already have.

    Writing it anyway would store several identical rows under one timestamp,
    and every average over the fact table would then weight those stations
    three times. So the collector compares `last_updated` and skips:

    ```text
    poll 1: 2509 rows, 2509 total
    poll 2: feed unchanged since 14:34:28, nothing written
    poll 3: feed unchanged since 14:34:28, nothing written
    poll 4: feed unchanged since 14:34:28, nothing written
    poll 5: 2509 rows, 5018 total
    ```

    That is a real run at `POLL_SECONDS=15`. Setting it below 60 costs you
    bandwidth and gains you nothing.

## A snapshot is not an event

This is the one modelling difference from a trip-based bike dataset, and it
matters for everything that follows.

GBFS gives you a **level** — "this dock holds 7 bikes right now" — not a
change. Departures and arrivals have to be derived by diffing consecutive
snapshots per station. You will do that in
[module 05](05-pushdown.md#the-query-that-hurts), and it turns out to be the
single most convincing argument in the workshop for moving work off Postgres.

## Next

[03 — The half that cannot move](03-spatial.md)

# 02 — Postgres, PostGIS and the schema

**[Previous](01-provision.md) · [Workshop home](index.md) · [Next: The feed](03-the-feed.md)**

## Goal

Create the two tables the whole workshop rests on, and understand the four
decisions baked into them.

## Create the schema

```bash
./scripts/psql.sh -f /sql/01-schema.sql
```

`psql` runs in a container with `sql/` mounted at `/sql`, which is why every
path in this workshop starts `/sql/`. Nothing was installed on your machine.

```sql
citibike.stations        station_key bigint PK, …, geom geometry(Point,4326)
citibike.station_status  status_id bigint PK, station_key bigint, polled_at, counts…
```

Two tables, and the split between them is the entire workshop:

| | What it holds | Size | Wants |
|---|---|---|---|
| `stations` | dock locations, capacity, names | ~2,500 rows, changes weekly | spatial indexes, geometry types |
| `station_status` | bikes and docks free, per station, per minute | +3.6M rows/day | column storage, fast aggregation |

## Four decisions worth understanding

Each of these is a thing that bites people later.

### The surrogate `station_key`

GBFS publishes `station_id` as a **string**, and it is not even consistently
shaped. A real sample from the live feed:

```text
2124037250266884686
2235288652396667648
dd482585-3028-453f-a98d-55019db9b26c     ← a UUID
```

The join key is the one value that crosses to the aggregating side on every
single row, so it gets to be a `bigint` that Postgres generates. This is also
what lets the geometry stay behind: the counting side never needs to know what
a point is.

### A primary key on the fact table

Logical replication needs a replica identity. Without a primary key ClickPipes
refuses the table outright:

```text
cannot be replicated because they don't have a valid replica identity
```

`REPLICA IDENTITY FULL` would also satisfy it, but a `bigint` key is what
ClickHouse wants to order and deduplicate on anyway.

### No foreign key from status to stations

A station can appear in `station_status.json` before `station_information.json`
catches up, and stations get retired between the two files. A constraint here
would reject real observations. The sync procedure in module 03 loads the
dimension first as a best-effort ordering, but the guarantee is deliberately
absent.

### A named publication, not `FOR ALL TABLES`

```sql
CREATE PUBLICATION citibike_pub
  FOR TABLE citibike.stations, citibike.station_status;
```

A `FOR ALL TABLES` publication sweeps up every scratch table anyone creates
while poking at the workshop, and each one then has to be dealt with
downstream.

## The index that will matter later

```sql
CREATE INDEX status_station_time_ix
    ON citibike.station_status (station_key, polled_at);
```

Remember this one. In [module 06](06-pushdown.md) it turns out to cover the
window function exactly, and that fact is the difference between a cheap
argument for ClickHouse and an honest one.

## Verify

```bash
./scripts/psql.sh -f /sql/02-verify.sql
```

Everything will be empty — no data is arriving yet. What you are checking is
that `postgis` is installed, both tables exist, and the publication names two
tables.

## A snapshot is not an event

One modelling note before the data starts arriving, because it shapes
everything downstream.

GBFS gives you a **level** — "this dock holds 7 bikes right now" — not a
change. Departures and arrivals have to be derived by diffing consecutive
snapshots per station. You will do that in
[module 06](06-pushdown.md#the-query-that-hurts), and it turns out to be the
most interesting query in the workshop.

## Next

[03 — The feed, with nothing on your laptop](03-the-feed.md)

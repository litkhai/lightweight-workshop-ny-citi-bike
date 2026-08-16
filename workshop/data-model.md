# The data model — every table, and how they relate

**[Workshop home](index.md) · [Overview](workshop-overview.md)**

Two engines, one namespace name, and five routes between them. This page is the
reference: what each table is, what writes it, what reads it, and what it joins
to. Read [the naming rule](workshop-overview.md#names) first if you have not.

## The whole picture

```text
                        Citi Bike GBFS  (public JSON, no key)
                                  │
                                  │ ① url() inside a refreshable MV, every minute
                                  ▼
┌─ ClickHouse ── database ny_citibike ──────────────────────────────────────┐
│                                                                          │
│   gbfs_stations   ◄── gbfs_stations_pull   (RMV, hourly, REPLACE)         │
│   gbfs_status     ◄── gbfs_pull            (RMV, 1 min, APPEND)           │
│        │                                                                 │
│        │ ② read as ny_citibike_ch.gbfs_*, copied by pg_cron              │
│        ▼                                                                 │
│                                                                          │
│   stations        ◄─┐                                                    │
│   station_status  ◄─┤ ④ ClickPipes CDC from Postgres                     │
│   sim_trips       ◄─┘                                                    │
│        │                                                                 │
│        │ ⑤ ny_citibike_ch.* — NOT a copy: queries go, answers return     │
└────────┼─────────────────────────────────────────────────────────────────┘
         │                    ▲                        │
         │                    │ ④                      │ ⑤
         ▼                    │                        ▼
┌─ Postgres ── schema ny_citibike ─────────────────────────────────────────┐
│                                                                          │
│   stations ────────────┐                                                 │
│     station_key PK     │ joined on station_key (bigint)                  │
│     geom  ← PostGIS    │                                                 │
│                        ├──── station_status   (② writes this)            │
│                        │        │                                        │
│                        │        │ ③ negative deltas → departures         │
│                        │        ▼                                        │
│                        └──── sim_trips        (module 09, generated)     │
│                                 ▲                                        │
│                    sim_pool ────┘  sim_origin, sim_params  (generator     │
│                                     internals, never replicated)         │
└──────────────────────────────────────────────────────────────────────────┘
```

Routes ① to ④ move rows. **Route ⑤ does not** — it is a query path, and the section on it explains why that distinction matters more than any other on this page.

`station_status` makes a round trip: ClickHouse → Postgres → ClickHouse. That is
route ② followed by route ④, and it is the single most confusing thing here.
[Module 03](03-the-feed.md) explains why it is a fair trade; the short version is
that the landing table and the fact table are different things that happen to
share a cloud.

## ClickHouse — database `ny_citibike`

| Table | Engine | ORDER BY | Written by | Read by |
|---|---|---|---|---|
| `gbfs_status` | ReplacingMergeTree | `(polled_at, station_id)` | RMV `gbfs_pull`, every minute, **APPEND** | Postgres, route ② |
| `gbfs_stations` | ReplacingMergeTree | `station_id` | RMV `gbfs_stations_pull`, hourly, **REPLACE** | Postgres, route ② |
| `stations` | ReplacingMergeTree | `station_key` | ClickPipes CDC | route ⑤, and joins |
| `station_status` | ReplacingMergeTree | `status_id` | ClickPipes CDC | route ⑤ |
| `sim_trips` | ReplacingMergeTree | `trip_id` | ClickPipes CDC | route ⑤ |
| `_peerdb_raw_mirror_…` | MergeTree | ClickPipes internal | ClickPipes | ClickPipes |

Two pairs that look alike and are not:

**`gbfs_status` vs `station_status`.** Same measurements, different identity.
`gbfs_status` keys on the GBFS **`station_id`** — a string, and not even a
consistently shaped one — because that is all the feed gives. `station_status`
keys on **`station_key`**, the bigint Postgres assigned. The conversion happens in
route ②, and it is the reason the counting side never has to know what a geometry
is.

**`gbfs_stations` vs `stations`.** The former is the raw dimension as published,
replaced hourly. The latter is Postgres's version of it, with `station_key` and
`geom` added — and `geom` is **not** in the ClickHouse copy, because ClickHouse has
no geometry type. That absence is the workshop's premise.

### Why `ReplacingMergeTree` twice, for different reasons

For `gbfs_status` it absorbs **duplicate polls**: the publisher moves on its own
~60s clock, so a minute-by-minute pull sometimes re-reads a file it already has.
The repeat arrives with the same `(polled_at, station_id)` and collapses at merge
time — no comparison, no bookkeeping.

For the three CDC tables it absorbs **updates and deletes**: logical replication
sends a new version of a row, and the engine keeps the latest by the primary key.
This is why `stations` briefly showed 10,036 rows for 2,509 stations — one version
per sync, until a merge collapsed them. (It no longer churns; see route ②.)

## Postgres — schema `ny_citibike`

| Table | Rows | Key | Written by | Replicated? |
|---|---|---|---|---|
| `stations` | ~2,500 | `station_key` PK, `station_id` UNIQUE | route ② | **yes** |
| `station_status` | +3.6M/day | `status_id` PK | route ② | **yes** |
| `sim_trips` | ~9.8M after backfill | `trip_id` PK | route ③ | **yes** |
| `sim_params` | 1 | `id` PK | you | no |
| `sim_pool` | ~150,000 | — | `sim_build_pool()` | no |
| `sim_origin` | ~2,500 | — | `sim_build_pool()` | no |

The three replicated tables are the ones named in `ny_citibike_pub`. The three
`sim_*` helpers are generator internals — deterministic given `stations`, so
copying them would be waste.

### The join keys

Everything hangs off one bigint:

```sql
station_status.station_key  →  stations.station_key
sim_trips.start_station_key →  stations.station_key
sim_trips.end_station_key   →  stations.station_key
sim_pool.start_station_key  →  stations.station_key
sim_pool.end_station_key    →  stations.station_key
```

Two things about that:

**There are no foreign key constraints.** Not an omission. A station can appear in
`station_status.json` before `station_information.json` catches up, and stations
retire between the two files; a constraint would reject real observations. Route ②
loads the dimension before the facts as a best-effort ordering, and that is the
whole guarantee.

**The key is a bigint on purpose.** GBFS `station_id` is a string, sometimes a
UUID. The join key is the one value that crosses to the aggregating side on every
row, so Postgres generates a bigint for it. That is what lets `geom` stay behind.

There is also a **text** join, used exactly once — route ② matches
`gbfs_status.station_id` to `stations.station_id` to look the bigint up. It is the
boundary where the feed's identity becomes the warehouse's.

## Postgres — schema `ny_citibike_ch`

Four (or five) foreign tables over **one** foreign server, `ny_citibike_ch_svr`,
pointed at ClickHouse's `ny_citibike` on port 8443.

| Foreign table | Imported by | Purpose |
|---|---|---|
| `gbfs_status`, `gbfs_stations` | [module 03](03-the-feed.md) | route ② reads these |
| `stations`, `station_status` | [module 06](06-pushdown.md) | route ⑤ — what the pushdown measures |
| `sim_trips` | module 06, if [module 09](09-trips.md) ran | the largest thing to push down |

Nothing writes through these. They are read paths.

## The five routes

### ① GBFS → ClickHouse `gbfs_*`

`url()` inside a refreshable materialized view. **`APPEND` on the status feed** —
without it each refresh replaces the target and you keep only the newest snapshot.
The station list deliberately omits `APPEND`: a dimension's newest copy is the
truth. Set up in [module 03](03-the-feed.md); file `clickhouse/01-ingest-rmv.sql`.

### ② ClickHouse `gbfs_*` → Postgres `stations` / `station_status`

`pg_cron` calls `ny_citibike.sync_from_clickhouse()` every minute. It reads the
foreign tables, upserts the dimension, then inserts facts newer than a
**high-water mark** — `max(polled_at)`, not "since last run", so a missed tick is
closed by the next one instead of leaving a permanent hole.

The dimension upsert only writes rows whose `name`, `capacity` or `geom` actually
changed. Without that condition it rewrote all 2,509 every minute: 3.6M no-op
writes a day, all of it WAL and all of it replicated onward.

File `sql/03-postgres-sync.sql`.

### ③ Postgres `station_status` → `sim_trips`

Optional, [module 09](09-trips.md). A negative delta in `num_bikes_available`
between consecutive snapshots is a departure; destination and duration are
modelled. `pg_cron` again, every minute, and it takes an advisory lock so a
running backfill makes it skip rather than queue.

File `sql/50-trip-generator.sql`.

### ④ Postgres → ClickHouse, by ClickPipes CDC

Logical replication of `ny_citibike_pub`. Needs `wal_level = logical` and a
replica identity on every table, which is why each has a bigint primary key.

Adding a table to the publication does **not** add it to an existing pipe — select
it in the console too. Set up in [module 05](05-clickpipes.md).

### ⑤ Postgres asks ClickHouse, by `pg_clickhouse`

**This one is not like the other four, and the arrow is the reason people misread
it.** Routes ① to ④ move rows: something is copied and afterwards a second copy
exists. Route ⑤ moves *no rows at all*.

`ny_citibike_ch` is a Postgres schema containing **foreign tables**, and a foreign
table stores nothing. It is a declaration that a table of this shape exists over
there. When you read one, Postgres does not fetch the table — it rewrites your
query, sends the rewritten text to ClickHouse, and receives the finished answer.

Here is an actual round trip, taken from the dashboard:

```sql
-- You write this, against Postgres, with no schema prefix:
SELECT extract(hour FROM polled_at)::int AS hour_utc,
       count(*)                          AS observations,
       round(avg(num_bikes_available), 1) AS avg_bikes
FROM station_status
GROUP BY 1 ORDER BY 1;
```

```sql
-- Postgres sends this to ClickHouse:
SELECT cast(toHour(polled_at), 'Nullable(Int32)'),
       count(*),
       round(avg(num_bikes_available), 1)
FROM ny_citibike.station_status
GROUP BY (cast(toHour(polled_at), 'Nullable(Int32)'))
ORDER BY ...
```

```text
-- 19 rows come back, in 125 ms. The 1.2M rows behind them never moved.
```

Three things to notice.

**The aggregation is in the remote text.** `count(*)`, `avg()` and the `GROUP BY`
all went. That is the pushdown, and it is the only reason 19 rows came back
instead of 1.2 million.

**The dialect was translated.** `extract(hour FROM …)` is Postgres; `toHour(…)` is
ClickHouse. You wrote one, the wrapper sent the other. This is what "one endpoint,
one dialect" buys — and also the limit of it, because anything the wrapper cannot
translate stays home and drags the rows back with it.

**Nothing was stored.** Ask again in a minute and the whole exchange happens
again. `ny_citibike_ch` is not a cache and not a copy; it is a query path with a
schema name.

The FDW also dials **outward from the Postgres server**, not from your laptop, so
both ends have to be somewhere the other can reach — which is why the workshop
uses ClickHouse Cloud on both sides rather than a local container.

File `sql/40-fdw-clickhouse.sql`; measured in [module 06](06-pushdown.md).

!!! note "Why an unqualified name reaches here first"
    The dashboard and the Lab set `search_path = ny_citibike_ch, ny_citibike`, so
    `FROM station_status` resolves to the foreign table and pushes down without
    anyone choosing it. Naming a table explicitly — `ny_citibike.stations` — opts
    back out, which is how the counter-example is built.

## What this buys, measured

The same query text against `ny_citibike` and `ny_citibike_ch`, on 9.8M
`sim_trips` rows, live:

| Query | `ny_citibike` | `ny_citibike_ch` | |
|---|---|---|---|
| Trips by hour | 10,404 ms | **465 ms** | 22× |
| Busiest routes — 4 relations | 8,234 ms | **1,606 ms** | 5.1× |
| Member vs casual | 1,691 ms | **527 ms** | 3.2× |

And the counter-example, which is the point of the whole arrangement: swap one
table for its local twin and the same query goes from 97 ms to 559 ms with no
error, no warning, and a plan that quietly drags 680,000 rows across the network.

## Tearing it down

Order matters, because an inactive replication slot retains WAL forever.

1. Stop the schedulers — `ny_citibike-sync`, `ny_citibike-simtrips`, and the two
   ClickHouse RMVs
2. **Delete** the ClickPipe (not pause), then confirm no slot survives in
   `pg_replication_slots`
3. Delete both services

[Module 08](08-wrap-up.md) has the commands.

# 09 — Trips, and why they have to be generated

**[Workshop home](index.md) · [Previous: Wrap-up](08-wrap-up.md)**

!!! danger "Everything this module creates is synthetic"
    `ny_citibike.sim_trips` contains **generated rows**. The `sim_` prefix is
    there so it appears in every query you write against it. Nothing in it should
    ever be quoted as a fact about how New Yorkers ride.

    Read the rest of this page before you use it for anything.

## Optional, and after the core path

Modules 00–08 are the workshop. This one is an extension, and it exists because
of a question the core path raises and cannot answer.

## The gap

Everything so far rests on `station_status`, and that is a **level**: how many
bikes are in each dock right now. It is a genuine time series — 3.6M rows a day
at one-minute resolution — and it is exactly the right shape for the pushdown
argument.

What it is not is a trip. There is no rider, no duration, no origin-destination
pair. That is not an oversight in this workshop; it is the GBFS specification,
which describes real-time availability and forbids the personal data a ride
record would need. Citi Bike publishes twelve feeds and not one of them carries
a ride:

```text
system_information  station_information  station_status  free_bike_status
system_hours  system_calendar  system_regions  system_pricing_plans
system_alerts  gbfs_versions  vehicle_types  gbfs
```

`free_bike_status` looks promising — track a bike id over time and you could
infer journeys. It returns **zero bikes**: Citi Bike is fully docked, so there is
nothing free-floating to follow.

## Why not the real trip archive

Real histories do exist. Lyft publishes monthly CSVs at
`s3.amazonaws.com/tripdata` with `started_at`, `ended_at`, both station ids, both
coordinates and `member_casual` — no key required. So why generate anything?

**Because ClickHouse cannot read the New York ones.** Measured against ClickHouse
Cloud 26.4.1:

| Archive | Size | Result |
|---|---|---|
| `JC-202602-…csv.zip` | 1.0 MB | reads fine — 25,809 rows |
| `JC-202510-…zip` | 3.6 MB | reads fine — 104,205 rows |
| `202604-citibike-tripdata.zip` | 164 MB | `BADZIPFILE` |
| `2014-citibike-tripdata.zip` | 224 MB | `BADZIPFILE` |

The small Jersey City archives work; every New York one fails. It is not the
compression (both are plain deflate), not zip64, not the entry count — the
central directories are unremarkable. It is size. And Jersey City alone is the
wrong city for a workshop called New York.

Note the syntax that does work, because it is worth knowing:

```sql
-- s3() reads inside an archive; url() rejects the :: syntax as a bad URI.
SELECT count() FROM s3('https://s3.amazonaws.com/tripdata/JC-202602-citibike-tripdata.csv.zip :: *.csv',
                       'CSVWithNames');
```

A monthly archive is also not live, which is the other half of the point.

## What the generator does instead

```bash
./scripts/psql.sh -f /sql/50-trip-generator.sql
```

Fully synthetic data is cheap to make and worth little, so this anchors
everything it can to what was actually observed. The result has two halves and
they are kept apart by a `source` column:

| Column | `source = 'observed'` | `source = 'modelled'` |
|---|---|---|
| `started_at` | **real** — a bike left in that minute | from a diurnal profile |
| `start_station_key` | **real** — that dock | weighted by capacity |
| how many | **real** — the observed negative delta | from a daily rate |
| `end_station_key` | model — distance decay over real geometry | same |
| `duration_s` | model — distance ÷ drawn speed | same |
| `rideable_type`, `member_casual` | model — share parameters | same |

The `observed` half is the interesting one: it is the snapshot-to-event
derivation from [module 06](06-pushdown.md#the-query-that-hurts) turned into a
table. Its ceiling is how long you have been collecting.

The `modelled` half is the backfill. There are no snapshots from three months
ago, so nothing can be anchored — those rows are a model end to end. **Any query
you intend to believe should say `WHERE source = 'observed'`.**

## The number that had to be calibrated

Summing every downward delta over 8.1 hours of live snapshots implied **244,000
trips/day**. Citi Bike publishes 100,000–150,000. The derivation lands high, and
it is worth understanding why, because the naive expectation is the opposite.

It does miss rides: a bike leaving and another arriving inside one snapshot
interval cancel out and are invisible. But it also invents them. A dock whose
count wobbles — a bike marked disabled and then available, a stale
`last_reported` — contributes departures nobody took. Over the same window gross
outflow was 83,834 and gross inflow 86,352, a net of +2,518: the two directions
balance, and both carry the noise.

So `sim_params.observed_scale` keeps each derived departure with probability
0.55, which brings the rate to about 134,000/day. What survives the sampling is
the part worth having — *which dock* and *which minute*, both measured. The count
is a calibration and the file says so.

## The peaks are in local time, and that took two goes

The backfill's hour weights describe a commuter day: a morning peak at 08:00, a
larger evening one at 18:00, a midday trough, quiet nights. Generated over 90
days the shape comes out exactly as intended.

The first version put them in the wrong clock. The weights were applied to UTC
hours, so the morning peak landed at **04:00 New York time** — and the aggregate
looked flawless, because a double-humped curve is a double-humped curve whatever
the labels say. Only reading the hours as a New Yorker catches it.

```sql
-- The profile is local; this is what makes hour 8 mean 8am to a rider.
(day + make_interval(hours => h)) AT TIME ZONE 'America/New_York'
```

Naming the zone rather than subtracting four hours also means DST is right in
both halves of the year.

If you generated a backfill before this was fixed, its peaks are four hours out.
Regenerate to correct it:

```sql
DELETE FROM ny_citibike.sim_trips WHERE source = 'modelled';
CALL ny_citibike.sim_backfill(90);
```

## Tuning it

Every knob is a column in one row:

```sql
SELECT * FROM ny_citibike.sim_params;

UPDATE ny_citibike.sim_params SET decay_m = 3000;   -- longer rides
CALL ny_citibike.sim_build_pool();                  -- rebuild after changing decay
```

`decay_m` is the one worth playing with. Destinations are drawn from each
station's 60 nearest neighbours weighted by `exp(-metres / decay_m)`, so 1500
puts the median ride near a kilometre. Raise it and the flow map fills with long
lines.

## Loading three months

```sql
CALL ny_citibike.sim_backfill(90);          -- ~9.4M rows, about 15 minutes
CALL ny_citibike.sim_backfill(7, 20000);    -- ~100k rows, seconds
```

Measured: 312,041 rows in 32 seconds, so roughly 11,000 rows/second.

!!! warning "This is the most expensive thing in the workshop"
    Measured at 4.4M rows in: **259 bytes each**, table plus its three indexes.
    Ninety days is therefore around 9.4M rows and **2.4 GB** — not the gigabyte
    a back-of-envelope on row width suggests — and every row replicates through
    ClickPipes. Run the small version first if you only want to see it work.

    The procedure commits once per day rather than once overall, so replication
    drains while it runs and a cancelled backfill keeps what it already wrote.

!!! danger "Cancelling psql does not cancel the backfill"
    A killed client leaves the backend running, holding locks the per-minute tick
    then queues behind. This happened while building the module. Find it:

    ```sql
    SELECT pid, state, query FROM pg_stat_activity WHERE query LIKE '%sim_%';
    SELECT pg_terminate_backend(<pid>);
    ```

    `sim_tick()` takes an advisory lock and **skips** the minute rather than
    waiting, so a running backfill no longer causes a pile-up. The high-water
    mark means the next tick collects whatever the skipped one missed.

## What you get for it

**A map that shows movement.** The Maps tab gains **Where rides go** —
`ST_MakeLine` between each origin and destination dock. That needs both
geometries, so it is another operation that cannot leave Postgres, and a more
convincing one than a Voronoi diagram.

**A much bigger table to push down**, and for the first time one where the clock
is evidence rather than decoration. Measured on Managed Postgres with 9.8M trips
in, all three running locally:

| Aggregate | Rows at the widest node | Local |
|---|---|---|
| Trips by hour | 9.8M | **12.2 s** |
| Busiest routes — 4 relations | 9.8M | **9.8 s** |
| Member vs casual | 4.1M | 1.6 s |
| *Fleet by hour, over `station_status`* | *650k* | *0.17 s* |

That last row is the point of the table. Everything in modules 00–08 answers in
milliseconds because the fact table is small; the workshop had to argue from the
plan alone. At ten million rows a wrong routing decision costs twelve seconds,
and the badge and the stopwatch finally agree.

**Busiest routes** is the one to run: a self-join on the trip table plus two joins
to `stations`. Four relations, and when the schema is the foreign one all four go
remote.

**A second scheduler.** `ny_citibike-simtrips` runs every minute alongside
`ny_citibike-sync`, so the trip table keeps growing on the same terms as
everything else: server-side, with nothing on your laptop.

## Replicating it

`sql/50-trip-generator.sql` adds `sim_trips` to `ny_citibike_pub` for you.
**That is not enough on its own** — adding a table to a publication does not add
it to a ClickPipe that already exists. Select it in the console as well, or the
foreign schema in module 06 will not see it.

## Teardown

`sim_trips` is the largest table you will create here.

```bash
./scripts/psql.sh -c "SELECT cron.unschedule('ny_citibike-simtrips')"
./scripts/psql.sh -c "DROP TABLE ny_citibike.sim_trips"
```

[Module 08](08-wrap-up.md) covers the rest.

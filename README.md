# NY Citi Bike — PostGIS meets ClickHouse

**[Documentation site](https://litkhai.github.io/lightweight-workshop-ny-citi-bike/) · [Workshop overview](workshop/workshop-overview.md) · [Start here](workshop/00-prerequisites.md) · [Instructor guide](workshop/instructor-guide.md)**

A self-service workshop built on a data feed that is **actually live**. New
York's Citi Bike publishes the state of every dock as public JSON with no API
key, and within ten minutes of starting your database is filling up with it in
real time.

You will keep the geography in **ClickHouse Managed Postgres**, push the
counting down to **ClickHouse Cloud**, and prove from the execution plan —
not from a stopwatch — which engine answered each query.

## The claim you are going to test

> You do not have to choose between Postgres and ClickHouse. Keep the geography
> in Postgres, send only the counting to ClickHouse, and neither engine does
> the thing it is bad at.

That is easy to say and easy to fake. A dashboard that shows numbers cannot
tell you which engine produced them, and "it felt fast" is not evidence — a
foreign table will happily drag millions of rows across the network and count
them locally. So every query here ends with a verdict read out of the plan.

## What you get

```text
Citi Bike GBFS            public JSON · no API key · ~2,500 stations · refreshed every 60s
      │  ClickHouse refreshable MV over url(), every minute
      ▼
ClickHouse Cloud          database ny_citibike
      gbfs_status                                  ← landing
      │  ny_citibike_ch.gbfs_status  +  pg_cron, every minute
      ▼
ClickHouse Managed Postgres   schema ny_citibike
      stations              PostGIS points  · 2,500 rows      · barely changes
      station_status        snapshots       · +3.6M rows/day  · only ever counted
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

Two things make that work.

**The join key is a `bigint`**, so no geometry ever has to cross.

**One namespace name on both engines** — the Postgres schema and the ClickHouse
database are both `ny_citibike`, and the mirrored tables keep their names. So
`ny_citibike.station_status` means the same thing on either side, and the only
difference between a local query and a pushed-down one is a schema prefix:

```text
ny_citibike.station_status      the real table, in Postgres
ny_citibike_ch.station_status   the same rows, answered by ClickHouse
```

When the verdict changes, the query text did not. That is what makes the
comparison evidence rather than anecdote.

## Requirements

- **Docker Desktop or Docker Engine with Compose v2** — `psql` and the dashboard run in containers; nothing else is installed. Ingestion needs no container at all: both schedulers are server-side
- **A ClickHouse Cloud account** — both services live there; a new organization starts with trial credit
- `curl`, `git`, and a browser

You do not need a Postgres client, Python, or a ClickHouse client on your
machine.

> **This costs money.** Two small managed services run for about two hours.
> On trial credit that is comfortably free; on a paid account it is small but
> not zero. The teardown is [module 08](workshop/08-wrap-up.md) — read its
> cost note before you start rather than after.

## Quick start

```bash
git clone https://github.com/litkhai/lightweight-workshop-ny-citi-bike.git
cd lightweight-workshop-ny-citi-bike

./scripts/preflight.sh          # checks Docker and the live feed — no account needed yet
```

Then follow [module 00](workshop/00-prerequisites.md). After provisioning the
two services in [module 01](workshop/01-provision.md):

```bash
./setup.sh                                    # asks for both services, writes .env

./scripts/psql.sh -f /sql/01-schema.sql             # PostGIS schema + publication
./scripts/clickhouse.sh -f /clickhouse/01-ingest-rmv.sql   # ClickHouse starts pulling
./scripts/psql.sh -f /sql/03-postgres-sync.sql -v ch_host=... -v ch_pass=...
./scripts/psql.sh -f /sql/02-verify.sql       # is it moving?

docker compose up -d --build ui               # http://localhost:8080
```

## Modules

| | Module | Time | |
|---|---|---|---|
| 00 | [Prerequisites](workshop/00-prerequisites.md) | 10 min | |
| 01 | [Provision the two services](workshop/01-provision.md) | 20 min | **console** |
| 02 | [Postgres, PostGIS and the schema](workshop/02-postgres-and-feed.md) | 10 min | |
| 03 | [The feed, with nothing on your laptop](workshop/03-the-feed.md) | 20 min | |
| 04 | [The half that cannot move](workshop/04-spatial.md) | 15 min | |
| 05 | [Replicate to ClickHouse](workshop/05-clickpipes.md) | 20 min | **console** |
| 06 | [Push the counting down](workshop/06-pushdown.md) | 25 min | |
| 07 | [The dashboard](workshop/07-dashboard.md) | 15 min | |
| 08 | [Wrap-up and teardown](workshop/08-wrap-up.md) | 10 min | |
| 09 | [Trips, generated](workshop/09-trips.md) — optional extra | 20 min | |

Two modules are **console walkthroughs** rather than scripts. Creating cloud
services and connecting a ClickPipe are tied to your own account and billing, so
the workshop clicks through them with you instead of asking for an
organization-wide API key. Everything else — including module 03's ClickHouse
statements, via `scripts/clickhouse.sh` — runs from this repository.

## What is in here

```text
workshop/       the guide — also published as the documentation site
                data-model.md  every table on both engines, and the five routes
clickhouse/     01 the refreshable MV that pulls the feed (runs on ClickHouse)
sql/            01 schema · 02 verify · 03 the Postgres side of ingestion
                03-check  can Postgres fetch https itself? (no, and why)
                10 spatial · 20 aggregates · 30 snapshot-to-events
                40 pg_clickhouse FDW
                50 the trip generator (optional, module 09)
setup.sh        asks for both services once and writes .env
scripts/        preflight · psql · clickhouse (both containerised) · explain-pushdown
ui/             the dashboard — two files, stdlib + psycopg
```

## Using a different city

Nothing is New York-specific except the map's initial centre. Any **docked**
system in the
[GBFS registry](https://github.com/MobilityData/gbfs/blob/master/systems.csv)
works — over 1,500 of them, none requiring a key.

ClickHouse is what fetches the feed, so the URL lives in the two `url()` calls
in `clickhouse/01-ingest-rmv.sql`. Resolve the discovery document once to find
them, then edit the file and re-run it:

```bash
curl -s https://gbfs.lyft.com/gbfs/2.3/dca-cabi/gbfs.json \
  | python3 -m json.tool | grep -A1 'station_status\|station_information'
```

Resolve rather than guess: the host serving the data is often not the one the
registry lists — Citi Bike registers `gbfs.citibikenyc.com` and serves from
`gbfs.lyft.com`.

## Credentials

This repository is public. `.env` is the only file holding real values and it
is gitignored. Scripts read connection details from the environment and fail
with instructions when they are missing; `scripts/psql.sh` masks the hostname
on the way out, because the hostname carries your service name and people
screenshot terminals during workshops.

## Verification status

Every claim here was run. This section says on what.

**Verified against the real products on 2026-08-15** — ClickHouse Managed
Postgres (PostgreSQL 18.4, PostGIS 3.6.4, pg_cron 1.6, pg_clickhouse 0.3) and
ClickHouse Cloud 26.4.1:

- ClickHouse fetching the live GBFS feed with `url()` — 1,073,635 bytes, parsed to 2,509 stations
- a refreshable materialized view with `REFRESH EVERY 1 MINUTE APPEND` accumulating snapshots unattended
- `pg_clickhouse` importing the landing tables and Postgres reading them
- `pg_cron` syncing forward every minute, unattended for seven hours: **1.38M rows, 0 duplicate `(station_key, polled_at)` pairs**
- the schema, the publication, and all five query files

**Verified end to end on 2026-08-16**, same pair of services, with ClickPipes
connected and module 09's generated trip table replicated:

- **the pushdown, from the plan.** One query text, no schema prefix, resolved through `search_path`: a single `Foreign Scan` whose `Remote SQL` carries the join, the `GROUP BY` and the aggregates
- **the counter-example.** The same text with one table pinned local — `dragged`, `Remote SQL` selecting columns only, no error and no warning
- **timings that mean something**, over 9.8M trips: trips-by-hour **10,404 ms** local against **465 ms** pushed; a four-relation join 8,234 against 1,606
- **the dialect translation** — `extract(hour FROM …)` leaving as `toHour(…)`
- all ten dashboard checkpoints green

**Verified on a local PostgreSQL 17 + PostGIS 3.6.4 container:** the plan shape
of the window query — which turned out to be index-covered rather than sorting,
so module 06 makes the narrower argument that survives scrutiny.

**Three claims this repository made and measurement disproved**, all now
corrected in place rather than quietly dropped:

- `geom` does cross to ClickHouse. It arrives as `text`; `sql/40-fdw-clickhouse.sql` drops it from the foreign table afterwards so that reaching for it fails loudly instead of casting per row without an index
- deriving departures from snapshot deltas **over**-counts, not under-counts — 244k/day implied against a published 100–150k, because reporting noise moves counts down as often as riders do
- the dimension upsert rewrote all 2,509 stations every minute whether or not anything changed: 1,289,626 updates over 514 runs, on the table the workshop calls the half that barely changes

**A negative result, verified and kept:** Postgres cannot fetch the feed
itself. There is no `http` or `pg_net` extension in the catalogue; `plperlu`
installs cleanly but the server's Perl has no `IO::Socket::SSL` or
`Net::SSLeay`, so every https fetch dies. `sql/03-check-in-db-http.sql` re-runs
that check on your own service, because it is the image rather than a
permission and a platform update could change it.

**Still written from the product documentation rather than run:** the console
click-throughs in [01](workshop/01-provision.md) (provisioning) and
[05](workshop/05-clickpipes.md) (creating the ClickPipe). The pipe itself has
been connected and everything downstream of it measured — what is unverified is
the sequence of screens, which is exactly the part that drifts. Both modules
describe what you are looking for alongside the current labels.

If a step does not match what you see, that is worth an
[issue](https://github.com/litkhai/lightweight-workshop-ny-citi-bike/issues).

## License

[MIT](LICENSE).

Citi Bike system data is published by Lyft Bikes and Scooters, LLC under the
[GBFS](https://gbfs.org) specification and is fetched at run time, not
redistributed here. MapLibre GL JS is loaded from a CDN under its own licence.
ClickHouse is a registered trademark of ClickHouse, Inc.; this is an
independent educational workshop and not an official ClickHouse product.

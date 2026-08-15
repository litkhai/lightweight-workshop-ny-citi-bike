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
      │  poll
      ▼
ClickHouse Managed Postgres
      bike.stations        PostGIS points  · 2,500 rows      · barely changes
      bike.station_status  snapshots       · +3.6M rows/day  · only ever counted
      │  ClickPipes (Postgres CDC)
      ▼
ClickHouse Cloud
      mirror of both tables
      ▲
      │  pg_clickhouse — foreign tables, back in the Postgres session
      │
Your SQL: geometry stays local, aggregates run remotely
      │
      ▼
Dashboard (Docker) — badges every query with the engine that answered
```

The join key is a `bigint`, so no geometry ever has to cross. That is the
whole trick.

## Requirements

- **Docker Desktop or Docker Engine with Compose v2** — `psql`, the collector and the dashboard all run in containers; nothing else is installed
- **A ClickHouse Cloud account** — both services live there; a new organization starts with trial credit
- `curl`, `git`, and a browser

You do not need a Postgres client, Python, or a ClickHouse client on your
machine.

> **This costs money.** Two small managed services run for about two hours.
> On trial credit that is comfortably free; on a paid account it is small but
> not zero. The teardown is [module 07](workshop/07-wrap-up.md) — read its
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
cp .env.example .env && $EDITOR .env      # paste both sets of credentials

./scripts/psql.sh -f /sql/01-schema.sql   # PostGIS schema + publication
docker compose up -d --build collector    # the live feed starts here
docker compose logs -f collector

./scripts/psql.sh -f /sql/02-verify.sql   # is it moving?
docker compose up -d --build ui           # http://localhost:8080
```

## Modules

| | Module | Time | |
|---|---|---|---|
| 00 | [Prerequisites](workshop/00-prerequisites.md) | 10 min | |
| 01 | [Provision the two services](workshop/01-provision.md) | 20 min | **console** |
| 02 | [Postgres, PostGIS and the live feed](workshop/02-postgres-and-feed.md) | 15 min | |
| 03 | [The half that cannot move](workshop/03-spatial.md) | 15 min | |
| 04 | [Replicate to ClickHouse](workshop/04-clickpipes.md) | 20 min | **console** |
| 05 | [Push the counting down](workshop/05-pushdown.md) | 25 min | |
| 06 | [The dashboard](workshop/06-dashboard.md) | 15 min | |
| 07 | [Wrap-up and teardown](workshop/07-wrap-up.md) | 10 min | |

Two modules are **console walkthroughs** rather than scripts. Creating cloud
services and connecting a ClickPipe are tied to your own account and billing,
so the workshop clicks through them with you instead of asking for an
organization-wide API key. Everything else runs from this repository.

## What is in here

```text
workshop/       the guide — also published as the documentation site
sql/            01 schema · 02 verify · 10 spatial · 20 aggregates
                30 snapshot-to-events · 40 pg_clickhouse FDW
scripts/        preflight · psql (containerised) · explain-pushdown
collector/      polls GBFS, COPYs snapshots into Postgres
ui/             the dashboard — two files, stdlib + psycopg
```

## Using a different city

Nothing is New York-specific except the map's initial centre. Any **docked**
system in the
[GBFS registry](https://github.com/MobilityData/gbfs/blob/master/systems.csv)
works — over 1,500 of them, none requiring a key. Set `GBFS_URL` in `.env` to
its discovery URL and everything else is unchanged.

## Credentials

This repository is public. `.env` is the only file holding real values and it
is gitignored. Scripts read connection details from the environment and fail
with instructions when they are missing; `scripts/psql.sh` masks the hostname
on the way out, because the hostname carries your service name and people
screenshot terminals during workshops.

## Verification status

This repository states what has been run and what has not, because a workshop
that overstates its own testing wastes the reader's time when it breaks.

**Verified** against a live Citi Bike feed and a local PostGIS 17 container on
2026-08-15:

- the GBFS discovery chain, and that the files are served from a different host than the registry lists
- `sql/01-schema.sql`, `02-verify.sql`, `10-spatial-postgres.sql`, `20-aggregate-pushdown.sql`, `30-snapshot-to-events.sql`
- the collector, end to end — 2,509 stations, real snapshots, and its duplicate-snapshot skip
- the plan shape of the window query, which turned out to be index-covered rather than sorting (module 05 says so)

**Written from the product documentation, not yet run end to end:** modules
[01](workshop/01-provision.md) (provisioning), [04](workshop/04-clickpipes.md)
(ClickPipes) and [05](workshop/05-pushdown.md) (`pg_clickhouse`), plus the
dashboard's ClickHouse side. Those need two paid cloud services and an account,
and the console walkthroughs describe what to look for rather than quoting
button labels that will drift.

If a step in those modules does not match what you see, that is worth an
[issue](https://github.com/litkhai/lightweight-workshop-ny-citi-bike/issues).

## License

[MIT](LICENSE).

Citi Bike system data is published by Lyft Bikes and Scooters, LLC under the
[GBFS](https://gbfs.org) specification and is fetched at run time, not
redistributed here. MapLibre GL JS is loaded from a CDN under its own licence.
ClickHouse is a registered trademark of ClickHouse, Inc.; this is an
independent educational workshop and not an official ClickHouse product.

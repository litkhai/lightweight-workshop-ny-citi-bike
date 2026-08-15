# 00 — Prerequisites

**[Workshop home](index.md) · [Next: Provision the two services](01-provision.md)**

## Goal

Have everything installed and verified before you create anything that bills.

## What you need

| | Why |
|---|---|
| **Docker Desktop / Engine with Compose v2** | `psql` and the dashboard run in containers. Nothing gets installed on your machine — and the collector needs no container at all, because the database runs it |
| **A ClickHouse Cloud account** | Both services live here. A new account starts with trial credit |
| **`curl` and `git`** | Fetching the repo and probing the feed |
| **A browser** | Two modules are console work |

No Postgres client, no Python, no ClickHouse client. If `docker` runs, you are
equipped.

## Get the repository

```bash
git clone https://github.com/litkhai/lightweight-workshop-ny-citi-bike.git
cd lightweight-workshop-ny-citi-bike
```

## Check the feed before anything else

The one dependency that is outside your control is the data source. Check it
first — if Citi Bike is having a bad day you want to know now, not after you
have provisioned two services.

```bash
./scripts/preflight.sh
```

Expected on a clean machine, before you have created anything:

```text
Local tooling
  ✓ Docker is running
  ✓ Compose v2 (2.x.x)
  ✓ curl

The data feed (public, no key)
  ✓ auto-discovery reachable
  ✓ station_status: 2509 stations right now

Managed Postgres
  ! no .env yet — that is expected before module 01
```

The station count moves as docks are installed and retired; anything in the
low-to-mid 2,000s is normal.

## What that check just proved

The feed needs **no API key**. That is not a convenience of this particular
city — the GBFS specification requires feeds to be public and forbids
authentication. Over 1,500 systems publish one, and
[the registry](https://github.com/MobilityData/gbfs/blob/master/systems.csv)
lists every one with its discovery URL.

It also means there is no secret in this workshop except your own database
password, which is why `.env` is the only gitignored file that matters.

## Using a different city

Nothing in this workshop is New York-specific except the map's initial centre.
Any **docked** system works — dockless scooter feeds have no stations to join
to, so they will not do.

The feed URL lives in the database, not in a config file. After module 02 you
change it with one statement:

```sql
-- Capital Bikeshare, Washington DC — 860 stations
UPDATE citibike.feed SET discovery_url =
  'https://gbfs.lyft.com/gbfs/2.3/dca-cabi/gbfs.json' WHERE id = 1;
CALL citibike.discover();
CALL citibike.load_stations();
```

!!! note "Always start from the discovery URL, never a data file"
    The host serving the JSON is frequently not the one in the registry. Citi
    Bike registers `gbfs.citibikenyc.com` and serves from `gbfs.lyft.com`. The
    `citibike.discover()` follows the chain properly; if you hardcode a URL from a
    blog post, you will be reading a stale mirror.

## Next

[01 — Provision the two services](01-provision.md)

# 01 — Provision the two services

**[Previous](00-prerequisites.md) · [Workshop home](index.md) · [Next: Postgres and PostGIS](02-postgres-and-feed.md)**

## Goal

Create one ClickHouse Managed Postgres service and one ClickHouse Cloud
service, in the same region, and record their credentials in `.env`.

!!! info "This module is console work"
    Creating services is tied to your account and your billing, so it is not
    scripted. Console wording changes faster than documentation, so each step
    below says **what you are looking for** as well as what it is currently
    called.

## Before you click anything

Both services should be in the **same cloud region**. The whole workshop is
about how little data crosses between them, and a cross-region hop adds latency
that has nothing to do with what you are measuring. Pick whichever region is
closest to you and use it for both.

## Step 1 — Sign in

Go to [console.clickhouse.cloud](https://console.clickhouse.cloud) and sign in
or create an account. A new organization starts with trial credit, which is
enough for this workshop several times over.

## Step 2 — Create the ClickHouse service

1. From the services list, choose **New service**.
2. Name it something you will recognise — `citibike-analytics`.
3. Pick your region.
4. Take the smallest / default size. This workshop moves kilobytes per query
   once pushdown works; you are not testing scale here.
5. Create it, and wait for the status to become running.

**Then collect the connection details.** Open the service and find **Connect**.
You want the **HTTPS** endpoint, not the native one:

| Field | Looks like | Goes in `.env` as |
|---|---|---|
| Host | `abc123.us-east-1.aws.clickhouse.cloud` | `CH_HOST` |
| Port | `8443` | `CH_PORT` |
| User | `default` | `CH_USER` |
| Password | shown once at creation | `CH_PASSWORD` |
| Database | `ny_citibike` — **not** the `default` shown here | `CH_DATABASE` |

!!! note "Why `ny_citibike` when the console says `default`"
    The Connect screen shows the service's default database. This workshop puts
    everything in a database called **`ny_citibike`**, created in module 03, to
    match the Postgres schema name exactly. Writing it into `.env` now means you
    do not have to come back for it.

!!! warning "The password is shown once"
    Copy it into `.env` now. If you lose it you can reset it from the service's
    settings, but you cannot read it back.

## Step 3 — Create the Managed Postgres service

ClickHouse Managed Postgres is a **separate product** in the same console, not
a feature of the ClickHouse service you just made. Look for **Postgres** in the
main navigation.

1. **New service**, name it `citibike-oltp`.
2. **Same region** as the ClickHouse service.
3. Smallest size. The fact table grows at roughly 3.6M rows a day, and a day or
   two of that is a few hundred megabytes.
4. Create it and wait.

**Then collect the connection details** from **Connect**:

| Field | Looks like | Goes in `.env` as |
|---|---|---|
| Host | `citibike-oltp-abc123.…….aws.pg.clickhouse.cloud` | `PGHOST` |
| Port | `5432` | `PGPORT` |
| User | `postgres` | `PGUSER` |
| Password | shown at creation | `PGPASSWORD` |
| Database | `postgres` | `PGDATABASE` |

### Allow your laptop to connect

Managed services do not accept connections from anywhere by default. Find the
service's network or IP access settings and add your current address.

Most consoles offer an "add my current IP" button — use that rather than
`0.0.0.0/0`. You are about to put a real password in a file on a laptop that
leaves the house; an open ingress rule turns a small mistake into a large one.

!!! tip "Two things to notice while you are in here"
    Look for **`wal_level`** (or a "logical replication" toggle) and confirm it
    is `logical`. ClickPipes in module 05 cannot replicate without it. On
    Managed Postgres this is usually the default — `preflight.sh` will tell you
    for certain in a moment.

    Also note whether the service lists **available extensions**. You need
    `postgis`, `pg_cron` and `pg_clickhouse` — the last two from module 03
    onward, because they are how the data arrives.

## Step 4 — Record the credentials

```bash
./setup.sh
```

It asks for the two sets of values you just collected and writes `.env` with
mode `600`. Nothing is sent anywhere. `FOREIGN_SCHEMA` is left empty on purpose
— module 06 sets it.

Both services are required from here on. It is tempting to skip the ClickHouse
half because "the Postgres part comes first", but **ClickHouse is what fetches
the feed** in module 03, so an empty `CH_HOST` means no data at all.

`.env` is gitignored. This repository is public and so is yours if you fork it:
never commit this file.

## Step 5 — Verify

```bash
./scripts/preflight.sh
```

Now that `.env` exists, the last two sections should fill in:

```text
Managed Postgres
  ✓ .env present
  ✓ connected — PostgreSQL 18.x
  ✓ postgis is available
  ✓ pg_cron is available
  ✓ pg_clickhouse is available
  ✓ wal_level = logical (ClickPipes can replicate)

ClickHouse Cloud
  ✓ CH_HOST and CH_PASSWORD are set
  ✓ HTTPS interface answered SELECT 1
```

A `✗` on either connection is worth fixing before you go on, and for Postgres it
is nearly always the IP allow-list. `pg_cron` and `pg_clickhouse` are both hard
requirements rather than niceties: together they are the ingestion path in
module 03, not just the pushdown in module 06.

## What you just built

Two managed services with nothing in them, in the same region, both reachable
from your laptop. Nothing is replicating yet and nothing is collecting yet.

## Next

[02 — Postgres, PostGIS and the schema](02-postgres-and-feed.md)

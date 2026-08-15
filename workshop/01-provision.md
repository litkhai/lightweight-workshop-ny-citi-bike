# 01 — Provision the two services

**[Previous](00-prerequisites.md) · [Workshop home](index.md) · [Next: Postgres and the live feed](02-postgres-and-feed.md)**

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
| Database | `default` | `CH_DATABASE` |

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
    is `logical`. ClickPipes in module 04 cannot replicate without it. On
    Managed Postgres this is usually the default — `preflight.sh` will tell you
    for certain in a moment.

    Also note whether the service lists **available extensions**. You need
    `postgis` and, for module 05, `pg_clickhouse`.

## Step 4 — Fill in `.env`

```bash
cp .env.example .env
$EDITOR .env
```

Paste in both sets of credentials. Leave `FOREIGN_SCHEMA` empty — module 05
sets it.

`.env` is gitignored. This repository is public and so is yours if you fork it:
never commit this file.

## Step 5 — Verify

```bash
./scripts/preflight.sh
```

Now that `.env` exists, the last section should fill in:

```text
Managed Postgres
  ✓ .env present
  ✓ connected — PostgreSQL 18.x
  ✓ postgis is available
  ✓ pg_clickhouse is available
  ✓ wal_level = logical (ClickPipes can replicate)
```

A `!` next to `pg_clickhouse` is survivable — you will get through module 04
and stop at 05. A `✗` on the connection is not: check the IP allow-list first,
that is nearly always what it is.

## What you just built

Two managed services with nothing in them, in the same region, both reachable
from your laptop. Nothing is replicating yet and nothing is collecting yet.

## Next

[02 — Postgres, PostGIS and the live feed](02-postgres-and-feed.md)

# 04 — Replicate to ClickHouse

**[Previous](03-spatial.md) · [Workshop home](index.md) · [Next: Push the counting down](05-pushdown.md)**

## Goal

Get both tables continuously replicating from Managed Postgres into ClickHouse
Cloud, using ClickPipes Postgres CDC.

!!! info "This module is console work"
    A ClickPipe is created against your account's services with your
    credentials. There is an API, but driving it here would mean handing this
    repository an organization-wide key — so the workshop clicks instead.
    Console labels change; each step says what you are looking for.

## Before you open the console

ClickPipes will reject the source if three things are not true. Check all three
now, because diagnosing them from the pipe's error message is much slower.

```bash
./scripts/psql.sh -c "SELECT current_setting('wal_level')"
./scripts/psql.sh -c "SELECT pubname, count(*) FROM pg_publication_tables GROUP BY 1"
./scripts/psql.sh -c "
  SELECT relname,
         CASE WHEN relreplident='d' THEN 'default (primary key)'
              WHEN relreplident='f' THEN 'full'
              ELSE relreplident::text END AS replica_identity
  FROM pg_class WHERE relname IN ('stations','station_status')"
```

You want:

| Check | Required | Why |
|---|---|---|
| `wal_level` | `logical` | Logical decoding is how CDC reads changes |
| publication | `bike_pub`, 2 tables | Created by `sql/01-schema.sql` |
| replica identity | `default (primary key)` on both | Without it the pipe refuses the table |

All three are set up by module 02 on a stock Managed Postgres service. If
`wal_level` is not `logical`, change it in the service's settings — it needs a
restart, so do that before going further.

## Step 1 — Start a new ClickPipe

In [console.clickhouse.cloud](https://console.clickhouse.cloud), open your
**ClickHouse service** (`citibike-analytics`, not the Postgres one), then find
**Data sources** / **ClickPipes** and choose to create a new one.

Pick **Postgres** as the source type. You are looking for the CDC connector,
not a one-off import.

## Step 2 — Point it at your Postgres

Enter the same values that are in your `.env`:

| Field | From `.env` |
|---|---|
| Host | `PGHOST` |
| Port | `5432` |
| Database | `postgres` |
| User | `postgres` |
| Password | `PGPASSWORD` |
| SSL / TLS | required |

!!! warning "Network access, again"
    The pipe connects from ClickHouse Cloud's network, not from your laptop.
    Adding your own IP in module 01 did nothing for this. If the connection
    test fails here, the Postgres service's allow-list is what to fix — the
    console usually shows the addresses to permit on this same screen.

Run the connection test before continuing. It fails fast and tells you
which of the three preconditions is missing.

## Step 3 — Choose the tables

Select **both**:

- `bike.stations`
- `bike.station_status`

!!! danger "Replicate both, or the pushdown will not work"
    It is tempting to replicate only the big fact table and keep the small
    dimension local. Do not.

    `pg_clickhouse` can push a join down only when **every** table in it lives
    on the same remote server. Join a foreign `station_status` to a local
    `stations` and the join has to happen in Postgres, which means every row
    comes back over the network first. You will see exactly this in module 05 —
    it is the counter-example — but you need both tables replicated to see the
    working case at all.

Leave the sync mode at the default (initial snapshot, then continuous CDC).

## Step 4 — Destination

Target database `default` and keep the table names as they are: `stations` and
`station_status`. Module 05's `IMPORT FOREIGN SCHEMA` expects those names.

If the connector offers an engine choice, `ReplacingMergeTree` keyed on the
primary key is the sensible default for CDC — it is how updates and deletes
from the source get collapsed.

## Step 5 — Start it and watch

Create the pipe. The initial snapshot of a few hundred thousand rows takes a
minute or two; then it switches to streaming.

From the Postgres side, you can now see the pipe existing:

```bash
./scripts/psql.sh -f /sql/02-verify.sql
```

The **replication** section, empty until now, fills in:

```text
== replication ==
 slot_name          | plugin   | active | unconsumed_wal
 clickpipes_xxxxx   | pgoutput | t      | 2384 kB
```

!!! note "`confirmed_flush_lsn` moves in steps, not continuously"
    The consumer confirms once a batch has landed downstream, so unconsumed WAL
    climbs and then drops rather than draining smoothly. Watching it for five
    seconds and concluding the pipe is stuck is a mistake worth not making.

## Step 6 — Confirm the rows arrived

In the console, open your ClickHouse service's SQL console:

```sql
SELECT count(*) FROM default.station_status;
SELECT count(*) FROM default.stations;
SELECT max(polled_at) FROM default.station_status;
```

Compare against Postgres:

```bash
./scripts/psql.sh -c "SELECT count(*) FROM bike.station_status"
```

They will not match exactly, and that is correct — the collector is still
inserting while you look. What matters is that ClickHouse's `max(polled_at)` is
within a minute or two of now.

## The one thing to monitor forever

```sql
SELECT count(*) FROM pg_replication_slots WHERE NOT active;
```

**An inactive replication slot retains WAL indefinitely and will fill the
disk.** If you pause or delete the pipe from the ClickHouse side without the
slot being cleaned up, Postgres keeps every change since the slot stopped
consuming, forever, waiting for a consumer that is not coming back.

This is the single most common way a Postgres CDC setup takes down a database.
Put that query in whatever you monitor, and see
[module 07](07-wrap-up.md) for cleaning it up properly at the end.

## Next

[05 — Push the counting down](05-pushdown.md)

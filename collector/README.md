# `collector/` — the container alternative

**The workshop does not use this by default.** Ingestion is server-side: a
ClickHouse refreshable materialized view over `url()` lands the feed, and
`pg_cron` plus `pg_clickhouse` copy it forward into Postgres. That is
[module 03](../workshop/03-the-feed.md), and it needs nothing running on your
laptop.

This directory is the other way to do it, and it is a legitimate choice:

- it does not involve ClickHouse in ingestion at all — GBFS goes straight to Postgres
- it is what you would reach for if your Postgres had an HTTP extension, or if you already run a scheduler somewhere
- it is easier to reason about: one loop, one process

Its cost is that it needs a machine that stays awake.

## Why the default is not a stored procedure

The obvious design — have Postgres fetch the URL itself — does not work on
ClickHouse Managed Postgres. There is no `http` extension and no `pg_net` in
the catalogue. `plperlu` is available and `CREATE EXTENSION plperlu` succeeds,
but the server's Perl has no TLS:

```text
IO::Socket::SSL 1.42 must be installed for https support
Net::SSLeay 1.49 must be installed for https support
```

Run `sql/03-check-in-db-http.sql` against your own service to confirm. The
certificates are present; it is the Perl build that lacks TLS, so this is an
image limitation rather than a permission — and a platform update could lift it.

## Run it

```bash
docker build -t citibike-collector ./collector
docker run -d --name citibike-collector --env-file .env \
  -e GBFS_URL=https://gbfs.citibikenyc.com/gbfs/2.3/gbfs.json \
  -e POLL_SECONDS=60 citibike-collector
docker logs -f citibike-collector
```

Or via Compose, which reads `.env` for you:

```bash
docker compose up -d --build collector
```

| Variable | Default | |
|---|---|---|
| `GBFS_URL` | Citi Bike | Discovery entry point, not a data file |
| `GBFS_LANG` | `en` | |
| `POLL_SECONDS` | `60` | Matches the feed's own ttl |
| `STATION_REFRESH_SECONDS` | `3600` | How often to re-read `station_information` |
| `PG*` | from `.env` | |

It writes to exactly the same tables, so every later module works unchanged.
**Skip module 03 if you go this route** — running both would store each
snapshot twice.

## How it compares

| | server-side (module 03) | this container |
|---|---|---|
| Keeps running when you close the laptop | yes | only if the container is somewhere that stays up |
| Schedulers involved | two: ClickHouse RMV + pg_cron | one: the loop in `collect.py` |
| Needs ClickHouse for ingestion | yes | no |
| Data path | GBFS → ClickHouse → Postgres | GBFS → Postgres |
| Where the feed URL lives | the RMV definition | an environment variable |
| Duplicate snapshots handled by | `ReplacingMergeTree` at merge time | comparing `last_updated` before writing |

Both follow the GBFS discovery chain rather than hardcoding a data URL, which
matters because the host serving the files is frequently not the one in the
registry — Citi Bike registers `gbfs.citibikenyc.com` and serves from
`gbfs.lyft.com`.

## License

[MIT](../LICENSE), same as the rest of the repository.

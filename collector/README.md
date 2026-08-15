# `collector/` — the fallback, not the lesson

**The workshop does not use this.** The feed is pulled by the database itself:
a `plperlu` function on a `pg_cron` schedule, installed by
[`sql/03-collector-in-db.sql`](../sql/03-collector-in-db.sql) and explained in
[module 02](../workshop/02-postgres-and-feed.md).

This directory exists for one situation: **your service will not let you create
`plperlu`.** Installing an untrusted procedural language needs superuser, and
having the extension in the catalogue is not the same as being permitted to
install it. `./scripts/preflight.sh` reports both facts separately.

If that is where you are, this container does the same job from outside.

## Run it

```bash
docker build -t citibike-collector ./collector
docker run -d --name citibike-collector --env-file .env \
  -e GBFS_URL=https://gbfs.citibikenyc.com/gbfs/2.3/gbfs.json \
  -e POLL_SECONDS=60 citibike-collector
docker logs -f citibike-collector
```

| Variable | Default | |
|---|---|---|
| `GBFS_URL` | Citi Bike | Discovery entry point, not a data file |
| `GBFS_LANG` | `en` | |
| `POLL_SECONDS` | `60` | Matches the feed's own ttl |
| `STATION_REFRESH_SECONDS` | `3600` | How often to re-read `station_information` |
| `PG*` | from `.env` | |

It writes to exactly the same tables, so every later module works unchanged.
Skip `sql/03-collector-in-db.sql` entirely if you go this route — running both
would store each snapshot twice.

## What it does differently

Nothing, functionally. It follows the same discovery chain, upserts the same
dimension, and applies the same duplicate-snapshot skip by comparing the feed's
`last_updated` against the last one stored.

The difference is operational, and it is the reason the database version is
preferred:

| | in-database | this container |
|---|---|---|
| Keeps running when you close the laptop | yes | only if the container is somewhere that stays up |
| Moving parts | none | one |
| Needs `plperlu` (superuser) | yes | no |
| Where the feed URL lives | a row in `bike.feed` | an environment variable |

## License

[MIT](../LICENSE), same as the rest of the repository.

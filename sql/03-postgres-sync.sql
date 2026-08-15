-- The ingestion half that runs ON POSTGRES.
--
--   ./scripts/psql.sh \
--       -v ch_host=xxx.clickhouse.cloud -v ch_pass='...' \
--       -f /sql/03-postgres-sync.sql
--
-- Run clickhouse/01-ingest-rmv.sql first. That gives ClickHouse a refreshable
-- materialized view fetching the GBFS feed every minute into a landing table.
-- This file teaches Postgres to reach that landing table and copy new
-- snapshots into its own, on a pg_cron schedule.
--
-- The result is a pipeline with no laptop in it: two schedulers, both
-- server-side, and nothing to keep alive.
--
--   GBFS ──https──► ClickHouse  refreshable MV, every minute
--                   citibike.gbfs_status          (landing)
--                        │
--                   pg_clickhouse foreign table
--                        │
--                   pg_cron, every minute
--                        ▼
--                   Postgres  citibike.station_status   (the fact table)
--
-- Note what this is NOT. The landing table is an ingestion detail. The fact
-- table's route back to ClickHouse is ClickPipes CDC, set up in module 05, and
-- that is the thing the workshop is actually about. The data does cross the
-- wire twice; see the module for why that is a fair trade.

\if :{?ch_host}
\else
  \echo 'set -v ch_host=... -v ch_pass=...  (and optionally -v ch_user=default)'
  \quit
\endif

\if :{?ch_user}
\else
  \set ch_user default
\endif

CREATE EXTENSION IF NOT EXISTS pg_clickhouse;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- --------------------------------------------------------------------------
-- Reach the landing tables
-- --------------------------------------------------------------------------
--
-- A server of its own, pointed at the `citibike` database on ClickHouse. This
-- is separate from the foreign server module 06 creates for the replicated
-- fact tables, and deliberately so: one is how data arrives, the other is what
-- the workshop measures.

DROP SERVER IF EXISTS citibike_ingest_svr CASCADE;

CREATE SERVER citibike_ingest_svr
    FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (host :'ch_host', port '9440', dbname 'citibike',
             secure 'true', driver 'binary');

CREATE USER MAPPING FOR CURRENT_USER
    SERVER citibike_ingest_svr
    OPTIONS (user :'ch_user', password :'ch_pass');

DROP SCHEMA IF EXISTS citibike_ingest CASCADE;
CREATE SCHEMA citibike_ingest;

IMPORT FOREIGN SCHEMA "citibike"
    LIMIT TO (gbfs_status, gbfs_stations)
    FROM SERVER citibike_ingest_svr
    INTO citibike_ingest;

-- --------------------------------------------------------------------------
-- Copy forward
-- --------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE citibike.sync_from_clickhouse()
LANGUAGE plpgsql
AS $$
DECLARE
    hwm timestamptz;
    n   integer;
    s   integer;
BEGIN
    -- The dimension first, so a station that appeared this minute has a
    -- station_key before the fact rows that reference it arrive.
    INSERT INTO citibike.stations
        (station_id, name, short_name, lat, lon, capacity, region_id, geom)
    SELECT station_id, name, short_name, lat, lon, capacity, region_id,
           ST_SetSRID(ST_MakePoint(lon, lat), 4326)
    FROM citibike_ingest.gbfs_stations
    -- 0/0 is not a missing coordinate, it is the Gulf of Guinea.
    WHERE lat <> 0 AND lon <> 0
    ON CONFLICT (station_id) DO UPDATE SET
        name      = EXCLUDED.name,
        capacity  = EXCLUDED.capacity,
        geom      = EXCLUDED.geom,
        last_seen = now();
    GET DIAGNOSTICS s = ROW_COUNT;

    -- A high-water mark rather than a "since last run" timestamp. If a run is
    -- missed — the scheduler was busy, the FDW timed out — the next one closes
    -- the gap instead of leaving a hole that nothing ever comes back for.
    SELECT coalesce(max(polled_at), '1970-01-01'::timestamptz)
      INTO hwm
      FROM citibike.station_status;

    INSERT INTO citibike.station_status
        (station_key, polled_at, last_reported,
         num_bikes_available, num_ebikes_available, num_docks_available,
         num_bikes_disabled, num_docks_disabled,
         is_installed, is_renting, is_returning)
    SELECT st.station_key, g.polled_at, g.last_reported,
           g.num_bikes_available, g.num_ebikes_available, g.num_docks_available,
           g.num_bikes_disabled, g.num_docks_disabled,
           g.is_installed::int::boolean,
           g.is_renting::int::boolean,
           g.is_returning::int::boolean
    FROM citibike_ingest.gbfs_status g
    JOIN citibike.stations st ON st.station_id = g.station_id
    WHERE g.polled_at > hwm;
    GET DIAGNOSTICS n = ROW_COUNT;

    RAISE NOTICE 'synced: % stations, % status rows newer than %', s, n, hwm;
END;
$$;

-- --------------------------------------------------------------------------
-- Schedule it
-- --------------------------------------------------------------------------
--
-- Every minute, matching the refresh rate on the other side. pg_cron will not
-- run two copies of a job at once, so a slow pull delays the next tick rather
-- than stacking on top of it.

SELECT cron.unschedule('citibike-sync')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'citibike-sync');

SELECT cron.schedule('citibike-sync', '* * * * *',
                     'CALL citibike.sync_from_clickhouse()');

-- First run now, rather than at the top of the minute.
CALL citibike.sync_from_clickhouse();

\echo ''
\echo '== the pipeline, with nothing running on your laptop =='
SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'citibike-sync';

SELECT count(*)                    AS rows,
       count(DISTINCT polled_at)   AS snapshots,
       count(DISTINCT station_key) AS stations,
       to_char(max(polled_at), 'HH24:MI:SS')            AS newest,
       extract(epoch FROM now() - max(polled_at))::int  AS seconds_behind
FROM citibike.station_status;

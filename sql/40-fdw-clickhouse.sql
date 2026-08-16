-- Point Postgres at ClickHouse with pg_clickhouse.
--
-- Run this AFTER ClickPipes has replicated ny_citibike.stations and
-- ny_citibike.station_status into the ny_citibike database on ClickHouse Cloud.
-- It does not move any data; it teaches Postgres how to reach tables that
-- already exist on the other side.
--
--   ./scripts/psql.sh \
--       -v ch_host=xxx.clickhouse.cloud \
--       -v ch_db=ny_citibike \
--       -v ch_user=default \
--       -v ch_pass='...' \
--       -f /sql/40-fdw-clickhouse.sql
--
-- Two things to know before running it:
--
-- 1. The FDW connects OUTWARD from the Postgres server. A ClickHouse running
--    on your laptop is not reachable from a managed Postgres in AWS. Both
--    sides have to be somewhere the other can dial — which is why this
--    workshop uses ClickHouse Cloud rather than a local container.
--
-- 2. PostGIS geometry has no ClickHouse equivalent. `geom` is deliberately not
--    part of what gets imported, and spatial predicates will never push down.
--    Keep the boundary at station_key.

\if :{?ch_host}
\else
  \echo 'set -v ch_host=... -v ch_db=... -v ch_user=... -v ch_pass=...'
  \quit
\endif

CREATE EXTENSION IF NOT EXISTS pg_clickhouse;

-- --------------------------------------------------------------------------
-- Server and credentials
-- --------------------------------------------------------------------------

-- The same server module 03 created, if you have run it. There is one server for
-- this workshop, not one per purpose — see sql/03-postgres-sync.sql for why the
-- second one was removed.
--
-- Created here too, so this file stands alone if you skipped ingestion. Not
-- dropped and recreated: that would take module 03's landing-table imports with
-- it, and this script has no way to put them back.
SELECT set_config('citibike.ch_host', :'ch_host', false);
SELECT set_config('citibike.ch_db',   :'ch_db',   false);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'ny_citibike_ch_svr') THEN
        EXECUTE format(
            'CREATE SERVER ny_citibike_ch_svr FOREIGN DATA WRAPPER clickhouse_fdw '
            'OPTIONS (host %L, port ''8443'', dbname %L, secure ''true'')',
            current_setting('citibike.ch_host'), current_setting('citibike.ch_db'));
    END IF;
END
$$;

DROP USER MAPPING IF EXISTS FOR CURRENT_USER SERVER ny_citibike_ch_svr;
CREATE USER MAPPING FOR CURRENT_USER
    SERVER ny_citibike_ch_svr
    OPTIONS (user :'ch_user', password :'ch_pass');

-- --------------------------------------------------------------------------
-- Import
-- --------------------------------------------------------------------------
--
-- The ClickHouse database is `ny_citibike` and so is the Postgres schema — the
-- names match on purpose. But the *foreign tables* cannot also be called
-- `ny_citibike` locally, because the real schema already owns that name. So they
-- land in `ny_citibike_ch`, and the arrangement reads:
--
--   ny_citibike.station_status      local Postgres, the real table
--   ny_citibike_ch.station_status   the same rows, answered by ClickHouse
--
-- Identical table name, identical column list, one prefix apart. That is what
-- makes the comparison in module 06 mean something: when the verdict changes,
-- the only thing that changed was where the work went.
--
-- If you ran module 03 this schema already exists and holds the two landing
-- tables. Only the two imported here are replaced, so re-running either script
-- leaves the other's alone.

CREATE SCHEMA IF NOT EXISTS ny_citibike_ch;

DROP FOREIGN TABLE IF EXISTS ny_citibike_ch.stations, ny_citibike_ch.station_status,
                             ny_citibike_ch.sim_trips;

-- sim_trips is listed but optional: it exists only if you ran module 09 and added
-- it to the ClickPipe. LIMIT TO quietly skips a table the remote does not have,
-- so this is safe on the core path — and re-running this file after module 09 is
-- what picks the trip table up.
IMPORT FOREIGN SCHEMA :"ch_db"
    LIMIT TO (stations, station_status, sim_trips)
    FROM SERVER ny_citibike_ch_svr
    INTO ny_citibike_ch;

-- --------------------------------------------------------------------------
-- Take the geometry back off the remote table
-- --------------------------------------------------------------------------
--
-- ClickPipes replicates every column, so `geom` came across — as `text`, since
-- ClickHouse has no geometry type. IMPORT FOREIGN SCHEMA then faithfully gave
-- the foreign table a text column called `geom`, which is a trap rather than a
-- feature:
--
--   ny_citibike.stations.geom      geometry   — GiST indexed, what ST_* wants
--   ny_citibike_ch.stations.geom   text       — a string that looks like it
--
-- A spatial query that reaches the remote table by search_path would then cast
-- text to geography for every row, silently, with no index — slower than the
-- local answer and indistinguishable from it in the output. Dropping the column
-- from the foreign table turns that into "column geom does not exist", which is
-- the truth and is also the lesson: geometry does not cross.
--
-- This does not touch ClickHouse. It only stops Postgres pretending the column
-- is usable from here.
ALTER FOREIGN TABLE ny_citibike_ch.stations DROP COLUMN IF EXISTS geom;

-- --------------------------------------------------------------------------
-- Did it work?
-- --------------------------------------------------------------------------

\echo ''
\echo '== foreign tables now visible =='
SELECT foreign_table_schema, foreign_table_name
FROM information_schema.foreign_tables
ORDER BY 1, 2;

\echo ''
\echo '== row counts on each side =='
SELECT 'postgres' AS side, count(*) FROM ny_citibike.station_status
UNION ALL
SELECT 'clickhouse',       count(*) FROM ny_citibike_ch.station_status;

\echo ''
\echo '== the moment of truth: does the aggregate go remote? =='
-- Look for a Foreign Scan carrying the GROUP BY in its Remote SQL. If the
-- Remote SQL selects columns only, every row crossed the network and was
-- counted here — which is a failure, however fast it felt.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT st.name, count(*), round(avg(ss.num_bikes_available), 1)
FROM ny_citibike_ch.station_status ss
JOIN ny_citibike_ch.stations st ON st.station_key = ss.station_key
GROUP BY st.name
ORDER BY count(*) DESC
LIMIT 10;

\echo ''
\echo '== and the counter-example: one local table breaks it =='
-- Same query, but joined to the LOCAL stations table. The join can no longer
-- happen on the remote side, so the rows come back to be joined here. This is
-- the single most common way a pushdown quietly stops working.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT st.name, count(*), round(avg(ss.num_bikes_available), 1)
FROM ny_citibike_ch.station_status ss
JOIN ny_citibike.stations st ON st.station_key = ss.station_key
GROUP BY st.name
ORDER BY count(*) DESC
LIMIT 10;

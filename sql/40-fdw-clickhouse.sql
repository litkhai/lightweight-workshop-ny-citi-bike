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

DROP SERVER IF EXISTS ny_citibike_ch_svr CASCADE;

CREATE SERVER ny_citibike_ch_svr
    FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (host :'ch_host', port '8443', dbname :'ch_db', secure 'true');

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

DROP SCHEMA IF EXISTS ny_citibike_ch CASCADE;
CREATE SCHEMA ny_citibike_ch;

IMPORT FOREIGN SCHEMA :"ch_db"
    LIMIT TO (stations, station_status)
    FROM SERVER ny_citibike_ch_svr
    INTO ny_citibike_ch;

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

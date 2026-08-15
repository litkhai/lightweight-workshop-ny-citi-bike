-- Point Postgres at ClickHouse with pg_clickhouse.
--
-- Run this AFTER ClickPipes has replicated bike.stations and bike.station_status
-- into ClickHouse Cloud. It does not move any data; it teaches Postgres how to
-- reach tables that already exist on the other side.
--
--   ./scripts/psql.sh \
--       -v ch_host=xxx.clickhouse.cloud \
--       -v ch_db=default \
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

DROP SERVER IF EXISTS clickhouse_svr CASCADE;

CREATE SERVER clickhouse_svr
    FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (host :'ch_host', port '8443', dbname :'ch_db', secure 'true');

CREATE USER MAPPING FOR CURRENT_USER
    SERVER clickhouse_svr
    OPTIONS (user :'ch_user', password :'ch_pass');

-- --------------------------------------------------------------------------
-- Import
-- --------------------------------------------------------------------------
--
-- A separate schema, not `bike`. Keeping the two namespaces apart is what
-- makes the demo legible: `bike.station_status` is local, `ch.station_status`
-- is remote, and the same query text against either one tells you where the
-- work went.

DROP SCHEMA IF EXISTS ch CASCADE;
CREATE SCHEMA ch;

IMPORT FOREIGN SCHEMA :"ch_db"
    LIMIT TO (stations, station_status)
    FROM SERVER clickhouse_svr
    INTO ch;

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
SELECT 'postgres' AS side, count(*) FROM bike.station_status
UNION ALL
SELECT 'clickhouse',       count(*) FROM ch.station_status;

\echo ''
\echo '== the moment of truth: does the aggregate go remote? =='
-- Look for a Foreign Scan carrying the GROUP BY in its Remote SQL. If the
-- Remote SQL selects columns only, every row crossed the network and was
-- counted here — which is a failure, however fast it felt.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT st.name, count(*), round(avg(ss.num_bikes_available), 1)
FROM ch.station_status ss
JOIN ch.stations st ON st.station_key = ss.station_key
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
FROM ch.station_status ss
JOIN bike.stations st ON st.station_key = ss.station_key
GROUP BY st.name
ORDER BY count(*) DESC
LIMIT 10;

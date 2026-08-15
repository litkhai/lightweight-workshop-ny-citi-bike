-- Is the Postgres half actually working? Run this after the collector has
-- been up for a few minutes.
--
--   ./scripts/psql.sh -f /sql/02-verify.sql

\echo '== extensions =='
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('postgis', 'pg_clickhouse')
ORDER BY extname;

\echo ''
\echo '== stations (the dimension) =='
SELECT count(*)                                    AS stations,
       count(*) FILTER (WHERE geom IS NOT NULL)    AS with_geometry,
       round(min(lat)::numeric, 3) || ' .. ' || round(max(lat)::numeric, 3) AS lat_range,
       round(min(lon)::numeric, 3) || ' .. ' || round(max(lon)::numeric, 3) AS lon_range,
       sum(capacity)                               AS total_docks
FROM citibike.stations;

\echo ''
\echo '== status (the fact table) =='
SELECT count(*)                          AS rows,
       count(DISTINCT station_key)       AS stations_seen,
       count(DISTINCT polled_at)         AS polls,
       to_char(min(polled_at), 'YYYY-MM-DD HH24:MI:SS') AS first_poll,
       to_char(max(polled_at), 'YYYY-MM-DD HH24:MI:SS') AS last_poll,
       extract(epoch FROM now() - max(polled_at))::int  AS seconds_behind,
       pg_size_pretty(pg_total_relation_size('citibike.station_status')) AS size
FROM citibike.station_status;

\echo ''
\echo '== is the feed still moving? (last 10 polls) =='
SELECT to_char(polled_at, 'HH24:MI:SS') AS poll,
       count(*)                         AS stations,
       sum(num_bikes_available)         AS bikes_out_there,
       sum(num_docks_available)         AS free_docks
FROM citibike.station_status
GROUP BY polled_at
ORDER BY polled_at DESC
LIMIT 10;

\echo ''
\echo '== replication (empty until ClickPipes is connected) =='
SELECT slot_name, plugin, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn))
           AS unconsumed_wal
FROM pg_replication_slots;

SELECT pubname,
       string_agg(schemaname || '.' || tablename, ', ' ORDER BY tablename) AS tables
FROM pg_publication_tables
GROUP BY pubname;

\echo ''
\echo '== foreign tables (empty until sql/40-fdw-clickhouse.sql has run) =='
SELECT foreign_table_schema, foreign_table_name
FROM information_schema.foreign_tables
ORDER BY 1, 2;

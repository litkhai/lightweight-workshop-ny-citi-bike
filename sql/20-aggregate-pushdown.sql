-- Five aggregates that should run on ClickHouse.
--
-- Every one of them reads the whole fact table and returns a handful of rows.
-- That ratio is the entire argument for pushdown: 3.6M rows a day in, 25 rows
-- out. Nothing here touches geometry.
--
-- The schema is a psql variable so the same file runs against either side:
--
--   ./scripts/psql.sh -v s=ny_citibike    -f /sql/20-aggregate-pushdown.sql  # local
--   ./scripts/psql.sh -v s=ny_citibike_ch -f /sql/20-aggregate-pushdown.sql  # ClickHouse
--
-- Run both and compare. Then run scripts/explain-pushdown.sh to find out
-- whether the second one actually pushed down, or just dragged the rows back.

\if :{?s}
\else
  \set s ny_citibike
\endif

\echo ''
\echo 'reading schema:' :s
\timing on

\echo ''
\echo '=== 1. System pulse: how much of the fleet is out at each hour? ==='
SELECT extract(hour FROM polled_at)::int AS hour_utc,
       count(DISTINCT polled_at)         AS polls,
       round(avg(num_bikes_available), 1) AS avg_bikes_at_dock,
       round(avg(num_docks_available), 1) AS avg_free_docks
FROM :s.station_status
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== 2. Busiest stations: total churn, by station ==='
-- The join is to stations, which is also replicated — so this whole statement
-- can run remotely. Mix in a *local* table and the pushdown collapses.
SELECT st.name,
       count(*)                              AS observations,
       round(avg(ss.num_bikes_available), 1) AS avg_bikes,
       max(ss.num_bikes_available)           AS peak_bikes,
       min(ss.num_bikes_available)           AS trough_bikes
FROM :s.station_status ss
JOIN :s.stations st ON st.station_key = ss.station_key
GROUP BY st.name
HAVING count(*) >= 5
ORDER BY peak_bikes DESC
LIMIT 15;

\echo ''
\echo '=== 3. Empty and full: how often does a station strand a rider? ==='
SELECT st.name,
       count(*) AS observations,
       round(100.0 * sum(CASE WHEN ss.num_bikes_available = 0 THEN 1 ELSE 0 END)
             / count(*), 1) AS pct_no_bikes,
       round(100.0 * sum(CASE WHEN ss.num_docks_available = 0 THEN 1 ELSE 0 END)
             / count(*), 1) AS pct_no_docks
FROM :s.station_status ss
JOIN :s.stations st ON st.station_key = ss.station_key
GROUP BY st.name
HAVING count(*) >= 5
ORDER BY pct_no_bikes DESC
LIMIT 15;

\echo ''
\echo '=== 4. Fleet mix: e-bikes as a share of what is available ==='
SELECT date_trunc('hour', polled_at) AS hour_utc,
       sum(num_bikes_available)      AS bikes,
       sum(num_ebikes_available)     AS ebikes,
       round(100.0 * sum(num_ebikes_available)
             / nullif(sum(num_bikes_available), 0), 1) AS pct_electric
FROM :s.station_status
GROUP BY 1
ORDER BY 1 DESC
LIMIT 24;

\echo ''
\echo '=== 5. Out of service: docks and bikes marked disabled ==='
SELECT date_trunc('hour', polled_at) AS hour_utc,
       sum(num_bikes_disabled)       AS bikes_disabled,
       sum(num_docks_disabled)       AS docks_disabled,
       count(*) FILTER (WHERE NOT is_renting)   AS station_polls_not_renting,
       count(*) FILTER (WHERE NOT is_returning) AS station_polls_not_returning
FROM :s.station_status
GROUP BY 1
ORDER BY 1 DESC
LIMIT 24;

\timing off

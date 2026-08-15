-- Turning snapshots into events.
--
-- GBFS gives you a level, not a change: "this dock holds 7 bikes right now".
-- What a bike-share analyst actually wants is the change — a bike left, a bike
-- arrived. You get that by diffing consecutive snapshots per station.
--
-- This is the most interesting workload in the workshop, and not for the
-- reason you would expect. Read the EXPLAIN at the bottom before assuming
-- anything: `status_station_time_ix` is (station_key, polled_at), which is
-- exactly what PARTITION BY station_key ORDER BY polled_at wants, so Postgres
-- reads straight down the index with **no sort at all**.
--
-- The honest argument is therefore narrower than "Postgres is slow at window
-- functions". It is that you can index for one access path and not for all of
-- them: change the partition or the ordering and the index stops covering it,
-- and then you get the sort. Module 06 spells that out.
--
--   ./scripts/psql.sh -v s=ny_citibike -f /sql/30-snapshot-to-events.sql
--
-- On ClickHouse the ordering is the table's own storage order, so the shapes
-- that fall off the Postgres index degrade far more gently there.

\if :{?s}
\else
  \set s ny_citibike
\endif

\echo ''
\echo 'reading schema:' :s
\timing on

\echo ''
\echo '=== the diff, one station at a time ==='
-- Only the sign matters for counting departures and arrivals. A negative delta
-- is bikes leaving; positive is bikes arriving. Rebalancing trucks show up as
-- large jumps and are deliberately left in — pretending they are rides would
-- be the dishonest choice, and they are interesting in their own right.
WITH deltas AS (
    SELECT station_key,
           polled_at,
           num_bikes_available
             - lag(num_bikes_available) OVER (PARTITION BY station_key ORDER BY polled_at)
             AS delta,
           extract(epoch FROM polled_at
             - lag(polled_at) OVER (PARTITION BY station_key ORDER BY polled_at))
             AS gap_seconds
    FROM :s.station_status
)
SELECT date_trunc('hour', polled_at) AS hour_utc,
       sum(CASE WHEN delta < 0 THEN -delta ELSE 0 END) AS bikes_departed,
       sum(CASE WHEN delta > 0 THEN  delta ELSE 0 END) AS bikes_arrived,
       sum(CASE WHEN abs(delta) >= 5 THEN 1 ELSE 0 END) AS likely_rebalance_events
FROM deltas
WHERE delta IS NOT NULL
  -- A gap much longer than the poll interval means we missed cycles, and the
  -- delta across that gap is not one event. Dropping it beats inventing rides.
  AND gap_seconds < 180
GROUP BY 1
ORDER BY 1 DESC
LIMIT 24;

\echo ''
\echo '=== busiest stations by derived departures ==='
WITH deltas AS (
    SELECT station_key,
           polled_at,
           num_bikes_available
             - lag(num_bikes_available) OVER (PARTITION BY station_key ORDER BY polled_at)
             AS delta,
           extract(epoch FROM polled_at
             - lag(polled_at) OVER (PARTITION BY station_key ORDER BY polled_at))
             AS gap_seconds
    FROM :s.station_status
)
SELECT st.name,
       sum(CASE WHEN d.delta < 0 THEN -d.delta ELSE 0 END) AS departed,
       sum(CASE WHEN d.delta > 0 THEN  d.delta ELSE 0 END) AS arrived,
       sum(CASE WHEN d.delta < 0 THEN -d.delta ELSE 0 END)
         - sum(CASE WHEN d.delta > 0 THEN d.delta ELSE 0 END) AS net_drain
FROM deltas d
JOIN :s.stations st ON st.station_key = d.station_key
WHERE d.delta IS NOT NULL AND d.gap_seconds < 180
GROUP BY st.name
ORDER BY departed DESC
LIMIT 15;

\echo ''
\echo '=== how expensive was that? ==='
-- Look for "Sort Method: external merge  Disk: ..." in the output. That line
-- is the workshop's argument in one string.
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY ON)
WITH deltas AS (
    SELECT station_key,
           num_bikes_available
             - lag(num_bikes_available) OVER (PARTITION BY station_key ORDER BY polled_at)
             AS delta
    FROM :s.station_status
)
SELECT sum(CASE WHEN delta < 0 THEN -delta ELSE 0 END) FROM deltas;

\timing off

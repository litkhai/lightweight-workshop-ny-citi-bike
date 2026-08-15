-- The ingestion half that runs ON CLICKHOUSE.
--
-- Paste this into the SQL console of your ClickHouse Cloud service, or pipe it
-- through the HTTPS interface. It does not run through psql — these are
-- ClickHouse statements.
--
-- Why ClickHouse is the thing doing the fetching:
--
--   Postgres cannot. ClickHouse Managed Postgres publishes ~145 extensions and
--   none of them is an HTTP client — no `http`, no `pg_net`, no plpython3u.
--   `plperlu` exists and installs cleanly, but the server's Perl build has no
--   TLS: IO::Socket::SSL and Net::SSLeay are both absent, so every https fetch
--   dies with "IO::Socket::SSL 1.42 must be installed for https support".
--   Run sql/03-check-in-db-http.sql against your own service to confirm.
--
--   ClickHouse has no such problem. url() is a first-class table function, and
--   a refreshable materialized view gives it a schedule. Between the two, the
--   feed arrives with nothing running on your laptop.

CREATE DATABASE IF NOT EXISTS citibike;

-- --------------------------------------------------------------------------
-- Landing tables
-- --------------------------------------------------------------------------
--
-- These are raw arrivals, not the workshop's fact table. The fact table lives
-- in Postgres and gets here later by a completely different route — ClickPipes
-- CDC, in module 05. Keeping the two apart is what makes the demo legible.

CREATE TABLE IF NOT EXISTS citibike.gbfs_status
(
    polled_at            DateTime,
    station_id           String,
    last_reported        DateTime,
    num_bikes_available  Int32,
    num_ebikes_available Int32,
    num_docks_available  Int32,
    num_bikes_disabled   Int32,
    num_docks_disabled   Int32,
    is_installed         UInt8,
    is_renting           UInt8,
    is_returning         UInt8
)
ENGINE = ReplacingMergeTree
ORDER BY (polled_at, station_id);

CREATE TABLE IF NOT EXISTS citibike.gbfs_stations
(
    station_id String,
    name       String,
    short_name String,
    lat        Float64,
    lon        Float64,
    capacity   Int32,
    region_id  String
)
ENGINE = ReplacingMergeTree
ORDER BY station_id;

-- --------------------------------------------------------------------------
-- The status feed: every minute, APPEND
-- --------------------------------------------------------------------------
--
-- APPEND is the important word. A refreshable materialized view without it
-- *replaces* the target on every run, which is right for a rollup and exactly
-- wrong for a feed you are accumulating — you would be left holding only the
-- newest snapshot.
--
-- Duplicate snapshots are handled by the ORDER BY plus ReplacingMergeTree: if
-- the publisher has not moved on, the same (polled_at, station_id) arrives
-- again and collapses at merge time. That is a different mechanism from the
-- one Postgres uses in module 03, and worth comparing.

DROP VIEW IF EXISTS citibike.gbfs_pull;

CREATE MATERIALIZED VIEW citibike.gbfs_pull
REFRESH EVERY 1 MINUTE APPEND
TO citibike.gbfs_status
AS
WITH src AS (
    SELECT json
    FROM url('https://gbfs.lyft.com/gbfs/2.3/bkn/en/station_status.json',
             'JSONAsString', $$json String$$)
)
SELECT
    toDateTime(JSONExtractUInt(json, 'last_updated')) AS polled_at,
    JSONExtractString(s, 'station_id')                AS station_id,
    toDateTime(JSONExtractUInt(s, 'last_reported'))   AS last_reported,
    JSONExtractInt(s, 'num_bikes_available')          AS num_bikes_available,
    JSONExtractInt(s, 'num_ebikes_available')         AS num_ebikes_available,
    JSONExtractInt(s, 'num_docks_available')          AS num_docks_available,
    JSONExtractInt(s, 'num_bikes_disabled')           AS num_bikes_disabled,
    JSONExtractInt(s, 'num_docks_disabled')           AS num_docks_disabled,
    JSONExtractInt(s, 'is_installed')                 AS is_installed,
    JSONExtractInt(s, 'is_renting')                   AS is_renting,
    JSONExtractInt(s, 'is_returning')                 AS is_returning
FROM src
ARRAY JOIN JSONExtractArrayRaw(JSONExtractRaw(json, 'data'), 'stations') AS s;

-- --------------------------------------------------------------------------
-- The station list: hourly, REPLACE
-- --------------------------------------------------------------------------
--
-- No APPEND here, deliberately. Stations are a dimension: the newest snapshot
-- of the list is the truth, and accumulating a copy every hour would be waste.

DROP VIEW IF EXISTS citibike.gbfs_stations_pull;

CREATE MATERIALIZED VIEW citibike.gbfs_stations_pull
REFRESH EVERY 1 HOUR
TO citibike.gbfs_stations
AS
WITH src AS (
    SELECT json
    FROM url('https://gbfs.lyft.com/gbfs/2.3/bkn/en/station_information.json',
             'JSONAsString', $$json String$$)
)
SELECT
    JSONExtractString(s, 'station_id') AS station_id,
    JSONExtractString(s, 'name')       AS name,
    JSONExtractString(s, 'short_name') AS short_name,
    JSONExtractFloat(s, 'lat')         AS lat,
    JSONExtractFloat(s, 'lon')         AS lon,
    JSONExtractInt(s, 'capacity')      AS capacity,
    JSONExtractString(s, 'region_id')  AS region_id
FROM src
ARRAY JOIN JSONExtractArrayRaw(JSONExtractRaw(json, 'data'), 'stations') AS s;

-- Do not wait an hour for the first station list.
SYSTEM REFRESH VIEW citibike.gbfs_stations_pull;

-- --------------------------------------------------------------------------
-- Did it work?
-- --------------------------------------------------------------------------

SELECT view, status, last_success_time, next_refresh_time, exception
FROM system.view_refreshes
WHERE database = 'citibike';

SELECT count() AS status_rows,
       uniqExact(polled_at)  AS snapshots,
       uniqExact(station_id) AS stations,
       min(polled_at) AS first,
       max(polled_at) AS last
FROM citibike.gbfs_status;

SELECT count() AS stations FROM citibike.gbfs_stations;

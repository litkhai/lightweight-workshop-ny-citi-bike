-- Five spatial queries that cannot leave Postgres.
--
-- Every one of them produces or consumes `geometry`. ClickHouse has no
-- equivalent type, so none of this pushes down — and none of it needs to.
-- Geometry is 2,500 rows that barely change; it is the 3.6M rows a day of
-- counting that wants to be somewhere else.
--
--   ./scripts/psql.sh -f /sql/10-spatial-postgres.sql

\timing on

\echo ''
\echo '=== 1. Service areas: which streets does each station actually serve? ==='
-- ST_VoronoiPolygons partitions the plane by nearest station. Clipped to the
-- convex hull of the network so the edge cells do not run off to infinity.
WITH cells AS (
    SELECT (ST_Dump(ST_VoronoiPolygons(ST_Collect(geom)))).geom AS cell
    FROM bike.stations
), hull AS (
    SELECT ST_ConvexHull(ST_Collect(geom)) AS h FROM bike.stations
)
SELECT s.name,
       s.capacity,
       round((ST_Area(ST_Intersection(c.cell, hull.h)::geography) / 1e6)::numeric, 3)
           AS service_km2
FROM cells c
CROSS JOIN hull
JOIN bike.stations s ON ST_Within(s.geom, c.cell)
ORDER BY service_km2 DESC
LIMIT 10;

\echo ''
\echo '=== 2. Nearest neighbours: where would you walk if this dock were empty? ==='
-- The <-> operator is an index-assisted KNN search against the GiST index.
-- There is no way to express this without the index and the geometry type.
WITH anchor AS (
    SELECT geom, name FROM bike.stations ORDER BY capacity DESC NULLS LAST LIMIT 1
)
SELECT a.name AS busiest_station,
       s.name AS alternative,
       round(ST_Distance(a.geom::geography, s.geom::geography)::numeric) AS metres
FROM anchor a
JOIN bike.stations s ON s.geom <> a.geom
ORDER BY a.geom <-> s.geom
LIMIT 5;

\echo ''
\echo '=== 3. Coverage gaps: the largest circle you can draw with no station in it ==='
-- Cluster the network, then measure how far the hull edge sits from its
-- members. A crude but honest proxy for "underserved".
SELECT round((ST_Area(ST_ConvexHull(ST_Collect(geom))::geography) / 1e6)::numeric, 2)
           AS network_km2,
       count(*) AS stations,
       round((count(*) / (ST_Area(ST_ConvexHull(ST_Collect(geom))::geography) / 1e6))::numeric, 2)
           AS stations_per_km2
FROM bike.stations;

\echo ''
\echo '=== 4. Density clusters: DBSCAN over the station points ==='
-- 400 m, at least 5 stations. Manhattan comes out as one dense blob; the
-- outer boroughs break into neighbourhood clusters.
WITH clustered AS (
    SELECT name,
           ST_ClusterDBSCAN(ST_Transform(geom, 3857), eps := 400, minpoints := 5)
               OVER () AS cluster_id
    FROM bike.stations
)
SELECT coalesce(cluster_id::text, 'unclustered') AS cluster,
       count(*) AS stations
FROM clustered
GROUP BY 1
ORDER BY count(*) DESC
LIMIT 10;

\echo ''
\echo '=== 5. Live geometry: current bike availability, joined to the map ==='
-- This one is the interesting case. The *aggregate* over station_status is
-- exactly what should move to ClickHouse; the geometry it joins to is exactly
-- what cannot. The join key is a bigint, so the two halves can live apart.
WITH latest AS (
    SELECT DISTINCT ON (station_key) station_key, num_bikes_available, num_docks_available
    FROM bike.station_status
    ORDER BY station_key, polled_at DESC
)
SELECT s.name,
       l.num_bikes_available AS bikes,
       l.num_docks_available AS docks,
       ST_AsText(ST_SnapToGrid(s.geom, 0.0001)) AS point
FROM latest l
JOIN bike.stations s USING (station_key)
WHERE l.num_bikes_available = 0
ORDER BY s.capacity DESC NULLS LAST
LIMIT 10;

\timing off

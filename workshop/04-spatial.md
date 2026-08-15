# 04 — The half that cannot move

**[Previous](02-postgres-and-feed.md) · [Workshop home](index.md) · [Next: Replicate to ClickHouse](05-clickpipes.md)**

## Goal

See concretely what PostGIS does that has no ClickHouse equivalent, so that
later, when the aggregates move, you know exactly why the geometry did not.

## Run the spatial set

```bash
./scripts/psql.sh -f /sql/10-spatial-postgres.sql
```

Five queries. Each one either produces or consumes `geometry`.

### 1. Service areas

```sql
ST_VoronoiPolygons(ST_Collect(geom))
```

Partitions the map so every point belongs to its nearest station. This is how
you answer "which streets does this dock actually serve" — and there is no way
to express it without a geometry type and a planar partition algorithm.

### 2. Nearest neighbours

```sql
ORDER BY a.geom <-> s.geom LIMIT 5
```

The `<->` operator is an index-assisted K-nearest-neighbour search against the
GiST index built in module 02. Without it you would compute distance to all
2,509 stations and sort. With it, the index returns them in distance order.

### 3 and 4. Density and clustering

`ST_ConvexHull` for network extent, `ST_ClusterDBSCAN` for neighbourhood
clusters. Manhattan comes out as one dense blob; the outer boroughs break
apart.

### 5. The interesting one

```sql
WITH latest AS (
    SELECT DISTINCT ON (station_key) station_key, num_bikes_available …
    FROM citibike.station_status ORDER BY station_key, polled_at DESC
)
SELECT s.name, l.num_bikes_available, ST_AsText(s.geom)
FROM latest l JOIN citibike.stations s USING (station_key)
WHERE l.num_bikes_available = 0
```

Read that carefully, because it is the workshop in miniature:

- the **aggregate** over `station_status` is exactly what should move to ClickHouse
- the **geometry** it joins to is exactly what cannot
- the **join key** is a `bigint`, which is what makes living apart possible

Right now both halves run in Postgres. After module 06 the first half will run
on ClickHouse and the second will not have moved an inch.

## Why geometry cannot follow

`geometry(Point, 4326)` is a PostGIS type. It carries a spatial reference
system, it indexes through GiST, and the ~300 `ST_*` functions that operate on
it are PostGIS's implementation.

ClickHouse has geo functions — `geoDistance`, H3, S2, polygon dictionaries —
and they are good. They are not the same functions, they do not take the same
types, and `pg_clickhouse` will not translate between them. So a predicate like
`ST_Within(s.geom, c.cell)` has nothing to push down to.

**This is fine.** Geometry here is 2,509 rows that change once a week. It is
the 3.6M rows a day of counting that wants to be somewhere else, and that
part has no geometry in it at all.

## Keep the boundary at the integer

The one rule that makes the whole arrangement work:

!!! tip "Nothing spatial in the aggregating query"
    If an aggregate's `WHERE` or `GROUP BY` touches `geom`, it cannot push
    down, and you will not get a warning — you get a plan that quietly drags
    every row back. Filter by district, by `station_key`, by name. Never by
    geometry.

    Need a spatial filter on an aggregate? Resolve it to a set of
    `station_key`s in Postgres first, then pass those integers to the
    aggregate. Two cheap queries beat one that silently falls back.

## Next

[04 — Replicate to ClickHouse](05-clickpipes.md)

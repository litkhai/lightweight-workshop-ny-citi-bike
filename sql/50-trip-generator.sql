-- Trips, generated in the database.
--
--   ./scripts/psql.sh -f /sql/50-trip-generator.sql
--
-- ============================================================================
-- READ THIS FIRST: these rows are NOT real trips.
-- ============================================================================
--
-- GBFS publishes a *level* — how many bikes are in each dock right now — and
-- nothing else. There is no trip feed, no rider, no origin-destination pair; the
-- specification forbids the personal data that would be needed for one. Confirm
-- it yourself: Citi Bike advertises twelve feeds and not one of them carries a
-- ride.
--
-- Real trip histories do exist, as monthly CSV archives at
-- s3.amazonaws.com/tripdata. This workshop does not use them, for a measured
-- reason: ClickHouse reads the small Jersey City archives from the URL happily,
-- and fails on every New York one with
--
--   Couldn't unpack zip archive: Code = BADZIPFILE
--
-- Small archives (1–4 MB) work, large ones (165 MB and up) do not, whatever the
-- entry count or nesting. Jersey City alone would be the wrong city for a
-- workshop called New York, and a monthly archive is not live in any case.
--
-- So the table below is *generated*, and it says so in its own name. Nothing
-- here should ever be quoted as a fact about how New Yorkers ride.
--
-- ============================================================================
-- What is real in it, and what is not
-- ============================================================================
--
-- Fully synthetic data is easy to write and worth very little, so this generator
-- anchors everything it can to what was actually observed:
--
--   started_at           REAL   the minute a bike actually left, from the feed
--   start_station_key    REAL   the dock it actually left
--   how many left        REAL   the size of the observed negative delta
--   end_station_key      MODEL  drawn from a distance-decay over real geometry
--   duration             MODEL  distance ÷ a speed drawn per rideable_type
--   rideable_type        MODEL  a share parameter
--   member_casual        MODEL  a share parameter
--
-- That is the `source = 'observed'` half, and it is the interesting one: it is
-- the snapshot-to-event derivation of sql/30 turned into a table. Its ceiling is
-- how long you have been collecting.
--
-- The backfill is different. There are no snapshots from three months ago, so
-- nothing can be anchored — those rows carry `source = 'modelled'` and their
-- departure times come from a diurnal profile. Keep the two apart in any query
-- you intend to believe:
--
--   WHERE source = 'observed'
--
-- ============================================================================
-- What it is good for
-- ============================================================================
--
-- The workshop needs a large, append-only, event-shaped fact table to push down,
-- and an origin-destination pair to draw on a map. This provides both without
-- pretending to be a trip history. Every aggregate in module 06 works on it, and
-- the geometry stays in Postgres exactly as it does for stations.

\timing on

-- --------------------------------------------------------------------------
-- Parameters, as a row you can edit
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ny_citibike.sim_params (
    id                  int PRIMARY KEY DEFAULT 1 CHECK (id = 1),

    -- Distance decay. A trip from A is drawn from A's neighbours with weight
    -- exp(-metres / decay_m), so most rides are short and a few are long. 1500
    -- puts the median around a kilometre, which is the right order for a docked
    -- system; raise it and the map fills with long lines.
    decay_m             double precision NOT NULL DEFAULT 1500,

    -- How many candidate destinations each station gets. The tail beyond this
    -- carries almost no weight, and the pool is what keeps generation set-based.
    neighbours          int NOT NULL DEFAULT 60,

    -- Metres per second, before noise. E-bikes are faster.
    speed_classic       double precision NOT NULL DEFAULT 3.2,
    speed_electric      double precision NOT NULL DEFAULT 4.6,

    -- Fixed seconds added per trip: unlocking, waiting at lights, docking.
    overhead_s          int NOT NULL DEFAULT 90,

    electric_share      double precision NOT NULL DEFAULT 0.55,
    member_share        double precision NOT NULL DEFAULT 0.78,

    -- A single station-minute losing more than this many bikes is a rebalancing
    -- truck, not a queue of riders. The observed generator clamps to it rather
    -- than emitting forty simultaneous departures from one dock.
    max_departures_per_minute int NOT NULL DEFAULT 8,

    -- Calibration, and the one number here that was fitted rather than guessed.
    --
    -- Summing every downward delta over 8.1 hours of real snapshots gave 83,834
    -- departures — an implied 244k/day, against the 100–150k Citi Bike actually
    -- publishes. Gross downward movement is not the same as rides: a dock whose
    -- count wobbles because a bike was marked disabled and then available again,
    -- or because last_reported went stale, contributes departures that nobody
    -- took. Over the same window gross inflow was 86,352 and the net was +2,518,
    -- so the two directions balance — the noise is symmetric, and both sides
    -- carry it.
    --
    -- So each derived departure is kept with this probability. 0.55 brings the
    -- rate to roughly 134k/day. What survives the sampling is the part worth
    -- having: *when* and *where*, which are measured. The count is calibrated.
    observed_scale       double precision NOT NULL DEFAULT 0.55,

    -- Backfill volume, *before* the seasonal and weekday factors below scale it.
    -- Asking for 120000 yields roughly 75k–120k depending on the date, which is
    -- the range Citi Bike actually runs. Do not read it as an exact target.
    backfill_trips_per_day int NOT NULL DEFAULT 120000
);

INSERT INTO ny_citibike.sim_params (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Every parameter is also added explicitly, because `CREATE TABLE IF NOT EXISTS`
-- silently does nothing when the table is already there. Adding a knob to the
-- definition above and re-running the file would then fail on the *procedures*
-- with "record p has no field ..." — which is exactly how this line got written.
-- Anything added to sim_params later needs a matching ALTER here.
ALTER TABLE ny_citibike.sim_params
    ADD COLUMN IF NOT EXISTS decay_m double precision NOT NULL DEFAULT 1500,
    ADD COLUMN IF NOT EXISTS neighbours int NOT NULL DEFAULT 60,
    ADD COLUMN IF NOT EXISTS speed_classic double precision NOT NULL DEFAULT 3.2,
    ADD COLUMN IF NOT EXISTS speed_electric double precision NOT NULL DEFAULT 4.6,
    ADD COLUMN IF NOT EXISTS overhead_s int NOT NULL DEFAULT 90,
    ADD COLUMN IF NOT EXISTS electric_share double precision NOT NULL DEFAULT 0.55,
    ADD COLUMN IF NOT EXISTS member_share double precision NOT NULL DEFAULT 0.78,
    ADD COLUMN IF NOT EXISTS max_departures_per_minute int NOT NULL DEFAULT 8,
    ADD COLUMN IF NOT EXISTS observed_scale double precision NOT NULL DEFAULT 0.55,
    ADD COLUMN IF NOT EXISTS backfill_trips_per_day int NOT NULL DEFAULT 120000;

-- --------------------------------------------------------------------------
-- The fact table
-- --------------------------------------------------------------------------
--
-- `sim_` is deliberate and permanent. It appears in every query anyone writes
-- against it, so nobody can read a chart off this table and forget what it is.

CREATE TABLE IF NOT EXISTS ny_citibike.sim_trips (
    -- Same reasoning as station_status: logical replication needs a replica
    -- identity, and ClickHouse wants a bigint to order on.
    trip_id           bigint PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,

    started_at        timestamptz NOT NULL,
    ended_at          timestamptz NOT NULL,
    start_station_key bigint      NOT NULL,
    end_station_key   bigint      NOT NULL,

    duration_s        integer     NOT NULL,
    meters            double precision,

    rideable_type     text        NOT NULL,   -- classic_bike | electric_bike
    member_casual     text        NOT NULL,   -- member | casual

    -- 'observed' — departure time, dock and count came from the live feed.
    -- 'modelled' — the whole row came from a profile. Never mix them silently.
    source            text        NOT NULL
);

-- "This station over time" and "everything in this window", the same two access
-- patterns station_status has, plus the destination side for OD queries.
CREATE INDEX IF NOT EXISTS sim_trips_started_ix
    ON ny_citibike.sim_trips (started_at);
CREATE INDEX IF NOT EXISTS sim_trips_start_station_ix
    ON ny_citibike.sim_trips (start_station_key, started_at);
CREATE INDEX IF NOT EXISTS sim_trips_end_station_ix
    ON ny_citibike.sim_trips (end_station_key, started_at);

-- Replicate it too, so module 06 has a second and much larger table to push
-- aggregates down over. Adding a table to the publication does NOT add it to an
-- existing ClickPipe — you have to select it in the console as well.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
         WHERE pubname = 'ny_citibike_pub' AND tablename = 'sim_trips') THEN
        ALTER PUBLICATION ny_citibike_pub ADD TABLE ny_citibike.sim_trips;
    END IF;
END
$$;

-- --------------------------------------------------------------------------
-- The destination pool
-- --------------------------------------------------------------------------
--
-- Choosing a destination per trip with a spatial query would mean a KNN search
-- for every one of millions of rows. Instead each station gets its neighbours
-- once, with cumulative weights normalised to [0,1), and picking a destination
-- becomes "draw a number, look up which bucket it lands in" — an index probe,
-- inside a set-based INSERT.
--
-- This is also the one place the generator needs PostGIS, and it needs it in the
-- way the rest of the workshop does: `<->` for the nearest-neighbour ordering
-- and `::geography` for metres rather than degrees.

CREATE TABLE IF NOT EXISTS ny_citibike.sim_pool (
    start_station_key bigint NOT NULL,
    end_station_key   bigint NOT NULL,
    meters            double precision NOT NULL,
    w_lo              double precision NOT NULL,
    w_hi              double precision NOT NULL
);

-- Origins for the backfill, weighted by capacity, as buckets in [0,1) — the same
-- draw-and-probe trick as sim_pool and for a sharper reason. Computing the
-- capacity CDF inline in a LATERAL re-ran a window function over all 2,509
-- stations *per generated trip*: two days of backfill did not finish in two
-- minutes. Precomputed, it is an index probe.
CREATE TABLE IF NOT EXISTS ny_citibike.sim_origin (
    station_key bigint NOT NULL,
    w_lo        double precision NOT NULL,
    w_hi        double precision NOT NULL
);

CREATE OR REPLACE PROCEDURE ny_citibike.sim_build_pool()
LANGUAGE plpgsql
AS $$
DECLARE
    p ny_citibike.sim_params;
    n bigint;
BEGIN
    SELECT * INTO p FROM ny_citibike.sim_params WHERE id = 1;

    TRUNCATE ny_citibike.sim_pool;

    INSERT INTO ny_citibike.sim_pool (start_station_key, end_station_key, meters, w_lo, w_hi)
    WITH nbr AS (
        SELECT a.station_key AS s, b.station_key AS e,
               ST_Distance(a.geom::geography, b.geom::geography) AS m
        FROM ny_citibike.stations a
        CROSS JOIN LATERAL (
            SELECT b2.station_key, b2.geom
            FROM ny_citibike.stations b2
            WHERE b2.station_key <> a.station_key AND b2.geom IS NOT NULL
            ORDER BY b2.geom <-> a.geom
            LIMIT p.neighbours
        ) b
        WHERE a.geom IS NOT NULL
    ), wt AS (
        SELECT s, e, m, exp(-m / p.decay_m) AS w FROM nbr
    ), cum AS (
        SELECT s, e, m, w,
               sum(w) OVER (PARTITION BY s)                                    AS tot,
               sum(w) OVER (PARTITION BY s ORDER BY e ROWS UNBOUNDED PRECEDING) AS run
        FROM wt
    )
    SELECT s, e, m, (run - w) / tot, run / tot
    FROM cum
    WHERE tot > 0;

    CREATE INDEX IF NOT EXISTS sim_pool_draw_ix
        ON ny_citibike.sim_pool (start_station_key, w_lo, w_hi);
    ANALYZE ny_citibike.sim_pool;

    TRUNCATE ny_citibike.sim_origin;
    INSERT INTO ny_citibike.sim_origin (station_key, w_lo, w_hi)
    WITH c AS (
        SELECT station_key, coalesce(capacity, 1) AS cap
        FROM ny_citibike.stations WHERE geom IS NOT NULL
    ), r AS (
        SELECT station_key, cap,
               sum(cap) OVER (ORDER BY station_key ROWS UNBOUNDED PRECEDING) AS run,
               sum(cap) OVER ()                                              AS tot
        FROM c
    )
    SELECT station_key, (run - cap)::double precision / tot, run::double precision / tot
    FROM r WHERE tot > 0;

    CREATE INDEX IF NOT EXISTS sim_origin_draw_ix
        ON ny_citibike.sim_origin (w_lo, w_hi);
    ANALYZE ny_citibike.sim_origin;

    SELECT count(*) INTO n FROM ny_citibike.sim_pool;
    RAISE NOTICE 'sim_pool: % candidate pairs over % stations, sim_origin: % buckets', n,
        (SELECT count(DISTINCT start_station_key) FROM ny_citibike.sim_pool),
        (SELECT count(*) FROM ny_citibike.sim_origin);
END;
$$;

-- --------------------------------------------------------------------------
-- Generate: observed window
-- --------------------------------------------------------------------------
--
-- A departure is a negative delta in num_bikes_available for one station between
-- consecutive snapshots. That is the derivation module 06 walks through, and it
-- is the only part of a trip the feed can actually tell us.
--
-- Two things it cannot tell us, both worth stating rather than hiding.
--
-- It misses churn. A bike leaving and another arriving inside the same snapshot
-- interval cancel out and are invisible, so some real rides never appear.
--
-- And it invents movement. Measured over 8.1 hours of live snapshots, summing
-- every downward delta implied 244k trips/day against a published 100–150k — so
-- despite missing churn it lands well *high*, because reporting noise moves
-- counts down as often as riders do. That is what `observed_scale` corrects, and
-- why the corrected figure is a calibration rather than a measurement.
--
-- What stays measured either way is the shape: which dock, and which minute.

CREATE OR REPLACE PROCEDURE ny_citibike.sim_generate_observed(
    since timestamptz DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    p    ny_citibike.sim_params;
    hwm  timestamptz;
    n    bigint;
BEGIN
    SELECT * INTO p FROM ny_citibike.sim_params WHERE id = 1;

    -- High-water mark over the observed rows only, so re-running never
    -- duplicates and a missed tick is closed by the next one. The backfill's
    -- modelled rows are older and must not move this mark.
    IF since IS NOT NULL THEN
        hwm := since;
    ELSE
        SELECT coalesce(max(started_at), '-infinity'::timestamptz)
          INTO hwm
          FROM ny_citibike.sim_trips
         WHERE source = 'observed';
    END IF;

    INSERT INTO ny_citibike.sim_trips
        (started_at, ended_at, start_station_key, end_station_key,
         duration_s, meters, rideable_type, member_casual, source)
    WITH d AS (
        SELECT station_key, polled_at,
               num_bikes_available
                 - lag(num_bikes_available) OVER (PARTITION BY station_key
                                                  ORDER BY polled_at) AS delta
        FROM ny_citibike.station_status
        WHERE polled_at > hwm - interval '2 minutes'
    -- `p` here is the plpgsql record, not a table alias. Joining sim_params in
    -- as well would make every `p.field` ambiguous at runtime.
    ), dep AS (
        SELECT station_key, polled_at,
               least(-delta, p.max_departures_per_minute) AS n
        FROM d
        WHERE delta < 0 AND polled_at > hwm
    ), one AS (
        -- One row per departing bike, with its own random draws. The
        -- observed_scale filter samples individual bikes rather than whole
        -- station-minutes, so it thins the volume without flattening the
        -- where-and-when that makes this half worth generating.
        SELECT dep.station_key, dep.polled_at,
               random() AS r_dest, random() AS r_type,
               random() AS r_member, random() AS r_speed,
               -- Spread departures across the interval instead of stacking them
               -- on the snapshot's own timestamp.
               dep.polled_at - (random() * interval '60 seconds') AS started_at
        FROM dep, generate_series(1, dep.n)
        WHERE random() < p.observed_scale
    )
    SELECT o.started_at,
           o.started_at + make_interval(secs => dur.duration_s),
           o.station_key, pool.end_station_key,
           dur.duration_s, pool.meters,
           dur.rideable_type,
           CASE WHEN o.r_member < p.member_share THEN 'member' ELSE 'casual' END,
           'observed'
    FROM one o
    JOIN ny_citibike.sim_pool pool
      ON pool.start_station_key = o.station_key
     AND o.r_dest >= pool.w_lo AND o.r_dest < pool.w_hi
    CROSS JOIN LATERAL (
        SELECT CASE WHEN o.r_type < p.electric_share
                    THEN 'electric_bike' ELSE 'classic_bike' END AS rideable_type,
               greatest(60, (p.overhead_s + pool.meters
                   / (CASE WHEN o.r_type < p.electric_share
                           THEN p.speed_electric ELSE p.speed_classic END
                      * (0.7 + 0.6 * o.r_speed)))::int) AS duration_s
    ) dur;

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'sim_trips: % observed trips generated after %', n, hwm;
END;
$$;

-- --------------------------------------------------------------------------
-- Generate: modelled backfill
-- --------------------------------------------------------------------------
--
-- No snapshots exist for last quarter, so there is nothing to anchor to and this
-- half is a model end to end. The shape it uses is the one every commuter system
-- has: two weekday peaks, a flatter and later weekend, and a seasonal scale.
--
-- Departure stations are weighted by capacity, which is the only real signal
-- available about how busy a dock is when you have no history for it.

CREATE OR REPLACE PROCEDURE ny_citibike.sim_backfill(
    days integer DEFAULT 90,
    trips_per_day integer DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    p     ny_citibike.sim_params;
    tpd   integer;
    d     date;
    -- Local date, to match the local-time hour profile below.
    day0  date := (now() AT TIME ZONE 'America/New_York')::date - days;
    total bigint := 0;
    n     bigint;
BEGIN
    SELECT * INTO p FROM ny_citibike.sim_params WHERE id = 1;
    tpd := coalesce(trips_per_day, p.backfill_trips_per_day);

    IF NOT EXISTS (SELECT 1 FROM ny_citibike.sim_pool) THEN
        RAISE EXCEPTION 'sim_pool is empty — CALL ny_citibike.sim_build_pool() first';
    END IF;

    -- Session-level, not transaction-level: this procedure COMMITs on every
    -- iteration, and an xact lock would be released by the first one. It is the
    -- same lock sim_tick tests, so the per-minute job steps aside for the whole
    -- backfill instead of queueing ninety times.
    IF NOT pg_try_advisory_lock(hashtext('ny_citibike.sim_generate')) THEN
        RAISE EXCEPTION 'another generator is already running — wait for it, or '
                        'find it in pg_stat_activity (a killed psql does not kill '
                        'the backend)';
    END IF;

    -- One day at a time, and one transaction per day. The loop alone was not
    -- enough: without the COMMIT below every day accumulated in a single
    -- transaction, so nothing was durable until the whole backfill finished and
    -- a timeout threw all of it away. Committing per day also hands ClickPipes
    -- ninety batches instead of one, which is what keeps replication moving while
    -- the backfill is still running.
    --
    -- A procedure may COMMIT; a function may not. That is the reason this is a
    -- procedure, and the reason it cannot be called from inside a query.
    FOR i IN 0 .. days - 1 LOOP
        d := day0 + i;

        INSERT INTO ny_citibike.sim_trips
            (started_at, ended_at, start_station_key, end_station_key,
             duration_s, meters, rideable_type, member_casual, source)
        WITH hours AS (
            -- Hour-of-day weights in NEW YORK LOCAL TIME, which is the whole
            -- reason for the AT TIME ZONE further down. Getting this wrong is
            -- easy and invisible in aggregate: the first version treated h as
            -- UTC, which put the morning commuter peak at 04:00 local. The shape
            -- looked perfect and the clock was four hours out.
            --
            -- Weekday: 8am and 6pm peaks. Weekend: one broad afternoon hump.
            SELECT h,
                   CASE WHEN extract(isodow FROM d) < 6
                        THEN 0.2 + 2.4 * exp(-((h - 8.3) ^ 2) / 4.0)
                                 + 3.0 * exp(-((h - 17.8) ^ 2) / 5.0)
                                 + 0.5 * exp(-((h - 12.5) ^ 2) / 8.0)
                        ELSE 0.2 + 2.2 * exp(-((h - 14.5) ^ 2) / 22.0)
                   END AS w
            FROM generate_series(0, 23) AS h
        ), norm AS (
            SELECT h, w / sum(w) OVER () AS share FROM hours
        ), per_hour AS (
            SELECT h,
                   -- Seasonal scale: quiet in winter, busy in summer.
                   (share * tpd
                     * (0.55 + 0.45 * sin((extract(doy FROM d) - 100) / 365.0 * 2 * pi()))
                     * (CASE WHEN extract(isodow FROM d) < 6 THEN 1.0 ELSE 0.82 END)
                   )::int AS n
            FROM norm
        ), one AS (
            -- Interpret the naive local timestamp as New York time. This is what
            -- makes the 8am weight land at 8am for a rider; DST is handled by the
            -- zone rather than by an offset that would be wrong half the year.
            SELECT (d + make_interval(hours => ph.h)
                      + (random() * interval '1 hour'))
                        AT TIME ZONE 'America/New_York' AS started_at,
                   random() AS r_start, random() AS r_dest, random() AS r_type,
                   random() AS r_member, random() AS r_speed
            FROM per_hour ph, generate_series(1, greatest(ph.n, 0))
        ), src AS (
            -- Departure station, weighted by capacity, as a range join against
            -- the precomputed buckets.
            SELECT o.*, org.station_key
            FROM one o
            JOIN ny_citibike.sim_origin org
              ON o.r_start >= org.w_lo AND o.r_start < org.w_hi
        )
        SELECT o.started_at,
               o.started_at + make_interval(secs => dur.duration_s),
               o.station_key, pool.end_station_key,
               dur.duration_s, pool.meters,
               dur.rideable_type,
               CASE WHEN o.r_member < p.member_share THEN 'member' ELSE 'casual' END,
               'modelled'
        FROM src o
        JOIN ny_citibike.sim_pool pool
          ON pool.start_station_key = o.station_key
         AND o.r_dest >= pool.w_lo AND o.r_dest < pool.w_hi
        CROSS JOIN LATERAL (
            SELECT CASE WHEN o.r_type < p.electric_share
                        THEN 'electric_bike' ELSE 'classic_bike' END AS rideable_type,
                   greatest(60, (p.overhead_s + pool.meters
                       / (CASE WHEN o.r_type < p.electric_share
                               THEN p.speed_electric ELSE p.speed_classic END
                          * (0.7 + 0.6 * o.r_speed)))::int) AS duration_s
        ) dur;

        GET DIAGNOSTICS n = ROW_COUNT;
        total := total + n;
        COMMIT;
        IF i % 10 = 0 THEN
            RAISE NOTICE 'backfill %/% days (%), % rows so far', i + 1, days, d, total;
        END IF;
    END LOOP;

    PERFORM pg_advisory_unlock(hashtext('ny_citibike.sim_generate'));
    RAISE NOTICE 'sim_trips: % modelled trips backfilled from %', total, day0;
END;
$$;

-- --------------------------------------------------------------------------
-- The micro-batch
-- --------------------------------------------------------------------------
--
-- Every minute, right after the sync job has landed the newest snapshot. Same
-- shape as ny_citibike-sync and for the same reason: the schedule lives in the
-- database, so closing your laptop does not stop it.

-- One advisory lock shared with sim_backfill, and the tick gives up rather than
-- waits. This is not defensive politeness; it is the fix for something that
-- actually happened.
--
-- A backfill runs for minutes. While one held its locks, every per-minute tick
-- queued behind it, and so did an ALTER TABLE — and because a killed psql does
-- not kill the backend, the original backfill kept running long after its client
-- was gone. Nothing recovered on its own. A tick that skips a minute costs
-- nothing: the high-water mark means the next one collects what this one missed.
CREATE OR REPLACE PROCEDURE ny_citibike.sim_tick()
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('ny_citibike.sim_generate')) THEN
        RAISE NOTICE 'sim_tick: another generator holds the lock, skipping this minute';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ny_citibike.sim_pool) THEN
        CALL ny_citibike.sim_build_pool();
    END IF;
    CALL ny_citibike.sim_generate_observed();
END;
$$;

SELECT cron.unschedule('ny_citibike-simtrips')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ny_citibike-simtrips');

SELECT cron.schedule('ny_citibike-simtrips', '* * * * *',
                     'CALL ny_citibike.sim_tick()');

-- --------------------------------------------------------------------------
-- Build the pool now; leave the backfill to you
-- --------------------------------------------------------------------------
--
-- The pool is small and instant. The backfill is not. Measured: 11,000 rows per
-- second, and 259 bytes each once the three indexes are counted — so 90 days is
-- about 9.4M rows, 2.4 GB, a quarter of an hour, and all of it replicates
-- through ClickPipes. Run it deliberately:
--
--   CALL ny_citibike.sim_backfill(90);          -- ~9.4M rows, ~15 min, 2.4 GB
--   CALL ny_citibike.sim_backfill(7, 20000);    -- ~100k rows, seconds
--
CALL ny_citibike.sim_build_pool();
CALL ny_citibike.sim_generate_observed();

\echo ''
\echo '== generated trips =='
SELECT source, count(*) AS trips,
       to_char(min(started_at), 'YYYY-MM-DD HH24:MI') AS first,
       to_char(max(started_at), 'YYYY-MM-DD HH24:MI') AS last,
       round(avg(duration_s))    AS avg_seconds,
       round(avg(meters))        AS avg_meters
FROM ny_citibike.sim_trips
GROUP BY source ORDER BY source;

\echo ''
\echo '== both schedulers =='
SELECT jobname, schedule, active FROM cron.job
WHERE jobname LIKE 'ny_citibike%' ORDER BY jobname;

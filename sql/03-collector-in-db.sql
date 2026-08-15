-- The collector, running inside the database.
--
-- No container, no cron on your laptop, no process to keep alive. Postgres
-- fetches the feed itself on a pg_cron schedule, and the workshop's moving
-- parts drop from three to one.
--
--   ./scripts/psql.sh -f /sql/03-collector-in-db.sql
--
-- How the pieces divide up:
--
--   bike.http_get()        plperlu. Transport only — one HTTPS GET, nothing else.
--   bike.discover()        resolves the GBFS discovery document to feed URLs
--   bike.load_stations()   station_information -> bike.stations, with geometry
--   bike.collect()         station_status -> bike.station_status, skipping repeats
--   cron.schedule(...)     calls bike.collect() every minute
--
-- The Perl does as little as possible on purpose: it is an *untrusted*
-- language, so every line in it runs as the OS user Postgres runs as. Parsing
-- is left to Postgres's own jsonb functions, where it belongs.

-- --------------------------------------------------------------------------
-- Extensions
-- --------------------------------------------------------------------------

-- plperlu is the only route to an outbound HTTPS request on ClickHouse Managed
-- Postgres: there is no `http` extension and no pg_net in the catalogue.
-- Creating it needs superuser.
CREATE EXTENSION IF NOT EXISTS plperlu;

-- Scheduling. pg_cron installs into one database — the service's default.
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- --------------------------------------------------------------------------
-- Where the feed lives
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS bike.feed (
    id                      integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    discovery_url           text NOT NULL,
    station_information_url text,
    station_status_url      text,
    -- The publisher's own stamp on the last snapshot we stored. This is what
    -- makes a repeated poll cheap instead of wrong.
    last_updated            timestamptz,
    discovered_at           timestamptz,
    last_poll_at            timestamptz,
    last_poll_result        text
);

INSERT INTO bike.feed (id, discovery_url)
VALUES (1, 'https://gbfs.citibikenyc.com/gbfs/2.3/gbfs.json')
ON CONFLICT (id) DO NOTHING;

-- --------------------------------------------------------------------------
-- Transport
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION bike.http_get(url text)
RETURNS text
LANGUAGE plperlu
AS $perl$
    use strict;
    use warnings;
    use HTTP::Tiny;

    my ($url) = @_;

    # HTTP::Tiny will not verify a certificate without being told where the
    # trust store is: it looks for the Mozilla::CA CPAN module, not for the
    # operating system's bundle. On a host that has certificates but not that
    # module you get "Couldn't find a CA bundle", which reads like a network
    # fault and is not one. Find the bundle ourselves.
    my ($ca) = grep { -r $_ } qw(
        /etc/ssl/certs/ca-certificates.crt
        /etc/pki/tls/certs/ca-bundle.crt
        /etc/ssl/ca-bundle.pem
        /etc/ssl/cert.pem
    );
    die "no CA bundle found on this host; cannot verify TLS\n" unless $ca;

    my $res = HTTP::Tiny->new(
        timeout    => 60,
        verify_SSL => 1,
        SSL_options => { SSL_ca_file => $ca },
        agent      => 'lightweight-workshop-ny-citi-bike/1.0 ',
    )->get($url);

    unless ($res->{success}) {
        # 599 is HTTP::Tiny's marker for "never reached the server". Its
        # content holds the real reason, and losing that turns every failure
        # into an indistinguishable timeout.
        die sprintf("GET %s failed: %s %s%s\n", $url,
                    $res->{status}, $res->{reason},
                    $res->{status} == 599 ? " — $res->{content}" : "");
    }
    return $res->{content};
$perl$;

COMMENT ON FUNCTION bike.http_get(text) IS
    'One HTTPS GET. plperlu because ClickHouse Managed Postgres offers no http extension.';

-- Untrusted PL runs as the OS user. Keep the function off PUBLIC.
REVOKE ALL ON FUNCTION bike.http_get(text) FROM PUBLIC;

-- --------------------------------------------------------------------------
-- Discovery
-- --------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE bike.discover()
LANGUAGE plpgsql
AS $$
DECLARE
    doc   jsonb;
    feeds jsonb;
    url   text;
BEGIN
    SELECT discovery_url INTO url FROM bike.feed WHERE id = 1;
    doc := bike.http_get(url)::jsonb;

    -- GBFS 1.x/2.x key `data` by language; 3.x drops the language layer.
    -- Accept both rather than pinning a version the operator may move off.
    feeds := COALESCE(doc #> '{data,en,feeds}',
                      doc #> '{data,feeds}',
                      (SELECT value -> 'feeds'
                         FROM jsonb_each(doc -> 'data') LIMIT 1));

    UPDATE bike.feed SET
        station_information_url = (
            SELECT f ->> 'url' FROM jsonb_array_elements(feeds) f
            WHERE f ->> 'name' = 'station_information'),
        station_status_url = (
            SELECT f ->> 'url' FROM jsonb_array_elements(feeds) f
            WHERE f ->> 'name' = 'station_status'),
        discovered_at = now()
    WHERE id = 1;

    -- The host serving the files is routinely not the one in the registry:
    -- Citi Bike registers gbfs.citibikenyc.com and serves from gbfs.lyft.com.
    -- Following the chain is the only thing that survives a CDN move.
    RAISE NOTICE 'station_information: %',
        (SELECT station_information_url FROM bike.feed WHERE id = 1);
    RAISE NOTICE 'station_status:      %',
        (SELECT station_status_url FROM bike.feed WHERE id = 1);

    IF (SELECT station_status_url IS NULL FROM bike.feed WHERE id = 1) THEN
        RAISE EXCEPTION 'this feed publishes no station_status — it is probably '
                        'a dockless system, which has no stations to join to';
    END IF;
END;
$$;

-- --------------------------------------------------------------------------
-- The dimension
-- --------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE bike.load_stations()
LANGUAGE plpgsql
AS $$
DECLARE
    url text;
    n   integer;
BEGIN
    SELECT station_information_url INTO url FROM bike.feed WHERE id = 1;
    IF url IS NULL THEN
        CALL bike.discover();
        SELECT station_information_url INTO url FROM bike.feed WHERE id = 1;
    END IF;

    -- Upserted, never replaced: retiring a station must not orphan the history
    -- that references it, and last_seen is what tells you one has quietly
    -- dropped out of the feed.
    WITH raw AS (
        SELECT jsonb_array_elements(bike.http_get(url)::jsonb #> '{data,stations}') AS s
    ), parsed AS (
        SELECT s ->> 'station_id'                AS station_id,
               s ->> 'name'                      AS name,
               s ->> 'short_name'                AS short_name,
               (s ->> 'lat')::double precision   AS lat,
               (s ->> 'lon')::double precision   AS lon,
               (s ->> 'capacity')::integer       AS capacity,
               s ->> 'region_id'                 AS region_id
        FROM raw
    )
    INSERT INTO bike.stations
        (station_id, name, short_name, lat, lon, capacity, region_id, geom)
    SELECT station_id, name, short_name, lat, lon, capacity, region_id,
           ST_SetSRID(ST_MakePoint(lon, lat), 4326)
    FROM parsed
    -- A station with no coordinates is useless to the geometry side, and 0/0
    -- plots in the Gulf of Guinea rather than failing loudly.
    WHERE lat IS NOT NULL AND lon IS NOT NULL AND NOT (lat = 0 AND lon = 0)
    ON CONFLICT (station_id) DO UPDATE SET
        name = EXCLUDED.name, short_name = EXCLUDED.short_name,
        lat  = EXCLUDED.lat,  lon = EXCLUDED.lon,
        capacity = EXCLUDED.capacity, region_id = EXCLUDED.region_id,
        geom = EXCLUDED.geom, last_seen = now();

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'stations: % upserted, % known', n, (SELECT count(*) FROM bike.stations);
END;
$$;

-- --------------------------------------------------------------------------
-- The fact table
-- --------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE bike.collect()
LANGUAGE plpgsql
AS $$
DECLARE
    url        text;
    seen       timestamptz;
    doc        jsonb;
    stamp      timestamptz;
    unknown    integer;
    n          integer;
BEGIN
    SELECT station_status_url, last_updated INTO url, seen FROM bike.feed WHERE id = 1;
    IF url IS NULL THEN
        CALL bike.discover();
        CALL bike.load_stations();
        SELECT station_status_url, last_updated INTO url, seen FROM bike.feed WHERE id = 1;
    END IF;

    doc   := bike.http_get(url)::jsonb;
    stamp := to_timestamp((doc ->> 'last_updated')::bigint);

    -- The publisher refreshes on its own ~60s clock. Poll faster and you fetch
    -- a file you already have; store it anyway and every average over the fact
    -- table weights those stations twice. Measured against the live feed: five
    -- polls at 15s produced one distinct last_updated.
    IF seen IS NOT NULL AND stamp <= seen THEN
        UPDATE bike.feed
           SET last_poll_at = now(),
               last_poll_result = format('unchanged since %s', to_char(stamp, 'HH24:MI:SS'))
         WHERE id = 1;
        RETURN;
    END IF;

    CREATE TEMP TABLE _ss ON COMMIT DROP AS
    SELECT s ->> 'station_id'                        AS station_id,
           (s ->> 'last_reported')::bigint           AS last_reported,
           (s ->> 'num_bikes_available')::integer    AS num_bikes_available,
           (s ->> 'num_ebikes_available')::integer   AS num_ebikes_available,
           (s ->> 'num_docks_available')::integer    AS num_docks_available,
           (s ->> 'num_bikes_disabled')::integer     AS num_bikes_disabled,
           (s ->> 'num_docks_disabled')::integer     AS num_docks_disabled,
           (s ->> 'is_installed')::int::boolean      AS is_installed,
           (s ->> 'is_renting')::int::boolean        AS is_renting,
           (s ->> 'is_returning')::int::boolean      AS is_returning
    FROM jsonb_array_elements(doc #> '{data,stations}') s;

    -- A station can appear in station_status before station_information
    -- catches up. Re-read the dimension rather than dropping the observation.
    SELECT count(*) INTO unknown
    FROM _ss LEFT JOIN bike.stations USING (station_id)
    WHERE bike.stations.station_key IS NULL;

    IF unknown > 0 THEN
        RAISE NOTICE '% unknown station id(s) — refreshing the dimension', unknown;
        CALL bike.load_stations();
    END IF;

    INSERT INTO bike.station_status
        (station_key, polled_at, last_reported,
         num_bikes_available, num_ebikes_available, num_docks_available,
         num_bikes_disabled, num_docks_disabled,
         is_installed, is_renting, is_returning)
    SELECT st.station_key, stamp, to_timestamp(x.last_reported),
           x.num_bikes_available, x.num_ebikes_available, x.num_docks_available,
           x.num_bikes_disabled, x.num_docks_disabled,
           x.is_installed, x.is_renting, x.is_returning
    FROM _ss x JOIN bike.stations st USING (station_id);

    GET DIAGNOSTICS n = ROW_COUNT;

    UPDATE bike.feed
       SET last_updated = stamp,
           last_poll_at = now(),
           last_poll_result = format('%s rows at %s', n, to_char(stamp, 'HH24:MI:SS'))
     WHERE id = 1;

    RAISE NOTICE 'collected % rows for %', n, stamp;
END;
$$;

-- --------------------------------------------------------------------------
-- Schedule it
-- --------------------------------------------------------------------------
--
-- Every minute, which matches the feed's own ttl. pg_cron will not run two
-- copies of the same job concurrently, so a slow fetch delays the next tick
-- rather than stacking on top of it.

SELECT cron.unschedule('gbfs-collect')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gbfs-collect');

SELECT cron.schedule('gbfs-collect', '* * * * *', 'CALL bike.collect()');

-- --------------------------------------------------------------------------
-- First run, now, rather than waiting for the top of the minute
-- --------------------------------------------------------------------------

CALL bike.discover();
CALL bike.load_stations();
CALL bike.collect();

\echo ''
\echo '== the collector is now the database =='
SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = 'gbfs-collect';
SELECT station_information_url, station_status_url, last_updated, last_poll_result
FROM bike.feed WHERE id = 1;

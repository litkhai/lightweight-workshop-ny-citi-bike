#!/usr/bin/env python3
"""Poll a GBFS feed and append every station snapshot to Postgres.

GBFS is not an API. It is a set of static JSON files served over HTTPS with no
authentication — the specification forbids requiring any — and there are no
query parameters, no pagination and no filtering. Every poll fetches the whole
file. For Citi Bike that is ~2,500 stations in about 940 KB.

That shape is why the fact table grows the way it does: 2,509 rows per poll,
1,440 polls a day at the default interval, so roughly 3.6M rows/day. It reaches
the point where Postgres stops enjoying the aggregates in about a week, which
is exactly the point of the workshop.

Discovery is done properly rather than by hardcoding URLs, because the host
that actually serves the files is often not the one in the registry: Citi Bike
registers gbfs.citibikenyc.com and serves from gbfs.lyft.com.

Standard library plus psycopg. No framework, no build step.
"""
import io
import json
import os
import signal
import sys
import time
import urllib.request
from datetime import datetime, timezone

import psycopg

# The auto-discovery entry point, not a data file. Everything else is found
# from here. Override to point the workshop at a different city.
GBFS_URL = os.environ.get(
    "GBFS_URL", "https://gbfs.citibikenyc.com/gbfs/2.3/gbfs.json")
GBFS_LANG = os.environ.get("GBFS_LANG", "en")

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))

# station_information changes rarely — new stations, retired stations, the
# occasional recount of docks. Re-reading it every poll would triple the
# bandwidth for nothing.
STATION_REFRESH_SECONDS = int(os.environ.get("STATION_REFRESH_SECONDS", "3600"))

USER_AGENT = os.environ.get(
    "GBFS_USER_AGENT",
    "lightweight-workshop-ny-citi-bike (+https://github.com/litkhai/lightweight-workshop-ny-citi-bike)")

STOP = False


def log(msg):
    print(f"{datetime.now(timezone.utc):%H:%M:%S} {msg}", flush=True)


def on_signal(signum, frame):
    global STOP
    STOP = True
    log("stopping after this cycle (Ctrl-C again to force)")


def fetch(url):
    """GET and parse one JSON document.

    A User-Agent is set on purpose. Several GBFS publishers rate-limit or
    reject the default Python one, and the failure looks like an outage rather
    than a rejection.
    """
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def discover(gbfs_url, lang):
    """Resolve the feed names this collector needs to real URLs.

    Returns (station_information_url, station_status_url).
    """
    doc = fetch(gbfs_url)
    data = doc["data"]

    # GBFS 1.x/2.x key `data` by language; 3.x drops the language layer. Accept
    # both rather than pinning a version the city might upgrade out from under.
    if lang in data:
        feeds = data[lang]["feeds"]
    elif "feeds" in data:
        feeds = data["feeds"]
    else:
        first = next(iter(data.values()))
        feeds = first["feeds"]

    by_name = {f["name"]: f["url"] for f in feeds}
    missing = {"station_information", "station_status"} - set(by_name)
    if missing:
        sys.exit(f"feed {gbfs_url} does not publish {', '.join(sorted(missing))} — "
                 f"it is probably a dockless system, which has no stations to join to")
    return by_name["station_information"], by_name["station_status"]


def dsn():
    missing = [v for v in ("PGHOST", "PGPASSWORD") if not os.environ.get(v)]
    if missing:
        sys.exit(f"missing {', '.join(missing)} — copy .env.example to .env "
                 f"and fill it in")
    return (f"host={os.environ['PGHOST']} port={os.environ.get('PGPORT', '5432')} "
            f"user={os.environ.get('PGUSER', 'postgres')} "
            f"password={os.environ['PGPASSWORD']} "
            f"dbname={os.environ.get('PGDATABASE', 'postgres')} "
            f"sslmode={os.environ.get('PGSSLMODE', 'require')}")


def upsert_stations(conn, url):
    """Load station_information and return {station_id: station_key}.

    Stations are upserted rather than replaced: retiring a station must not
    orphan the history that references it, and `last_seen` is what tells you a
    station has quietly dropped out of the feed.
    """
    doc = fetch(url)
    stations = doc["data"]["stations"]
    rows = []
    for s in stations:
        lat, lon = s.get("lat"), s.get("lon")
        # A station with no coordinates is useless to the geometry side, and
        # 0/0 shows up in the Gulf of Guinea rather than failing loudly.
        if lat is None or lon is None or (lat == 0 and lon == 0):
            continue
        rows.append((str(s["station_id"]), s.get("name"), s.get("short_name"),
                     lat, lon, s.get("capacity"), str(s.get("region_id") or "")))

    with conn.cursor() as cur:
        cur.execute("CREATE TEMP TABLE _si (station_id text, name text, "
                    "short_name text, lat float8, lon float8, capacity int, "
                    "region_id text) ON COMMIT DROP")
        with cur.copy("COPY _si FROM STDIN") as cp:
            for r in rows:
                cp.write_row(r)
        cur.execute("""
            INSERT INTO bike.stations
                (station_id, name, short_name, lat, lon, capacity, region_id, geom)
            SELECT station_id, name, short_name, lat, lon, capacity, region_id,
                   ST_SetSRID(ST_MakePoint(lon, lat), 4326)
            FROM _si
            ON CONFLICT (station_id) DO UPDATE SET
                name       = EXCLUDED.name,
                short_name = EXCLUDED.short_name,
                lat        = EXCLUDED.lat,
                lon        = EXCLUDED.lon,
                capacity   = EXCLUDED.capacity,
                region_id  = EXCLUDED.region_id,
                geom       = EXCLUDED.geom,
                last_seen  = now()
        """)
        cur.execute("SELECT station_id, station_key FROM bike.stations")
        keys = dict(cur.fetchall())
    conn.commit()
    log(f"stations: {len(rows)} in feed, {len(keys)} known")
    return keys


def ts(epoch):
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc)


def poll_status(conn, url, keys, si_url, last_seen_poll):
    """One cycle: fetch the snapshot, append every station's row.

    Returns (written, skipped, polled_at, keys). `written` is 0 when the
    publisher has not refreshed since the last cycle.
    """
    doc = fetch(url)
    polled_at = ts(doc.get("last_updated")) or datetime.now(timezone.utc)
    stations = doc["data"]["stations"]

    # The publisher stamps the file with its own last_updated, and refreshes it
    # about every 60s. Poll faster than that and you fetch a file you already
    # have. Writing it again would store N identical rows under one timestamp,
    # which quietly skews every average taken over the fact table — the
    # duplicated stations get N times the weight. Verified against the live
    # feed: five polls at 15s produced one distinct last_updated.
    if last_seen_poll is not None and polled_at <= last_seen_poll:
        return 0, 0, polled_at, keys

    # A station can show up in station_status before station_information
    # catches up. Re-read the dimension rather than dropping the observation.
    unknown = {str(s["station_id"]) for s in stations} - set(keys)
    if unknown:
        log(f"{len(unknown)} unknown station id(s) — refreshing the dimension")
        keys = upsert_stations(conn, si_url)

    buf = io.StringIO()
    written = skipped = 0
    for s in stations:
        key = keys.get(str(s["station_id"]))
        if key is None:
            skipped += 1
            continue
        lr = ts(s.get("last_reported"))
        buf.write("\t".join([
            str(key),
            polled_at.isoformat(),
            lr.isoformat() if lr else r"\N",
            str(s.get("num_bikes_available") if s.get("num_bikes_available") is not None else r"\N"),
            str(s.get("num_ebikes_available") if s.get("num_ebikes_available") is not None else r"\N"),
            str(s.get("num_docks_available") if s.get("num_docks_available") is not None else r"\N"),
            str(s.get("num_bikes_disabled") if s.get("num_bikes_disabled") is not None else r"\N"),
            str(s.get("num_docks_disabled") if s.get("num_docks_disabled") is not None else r"\N"),
            "t" if s.get("is_installed") else "f",
            "t" if s.get("is_renting") else "f",
            "t" if s.get("is_returning") else "f",
        ]) + "\n")
        written += 1
    buf.seek(0)

    with conn.cursor() as cur:
        with cur.copy("""COPY bike.station_status
            (station_key, polled_at, last_reported,
             num_bikes_available, num_ebikes_available, num_docks_available,
             num_bikes_disabled, num_docks_disabled,
             is_installed, is_renting, is_returning) FROM STDIN""") as cp:
            cp.write(buf.read())
    conn.commit()
    return written, skipped, polled_at, keys


def main():
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    log(f"discovering {GBFS_URL}")
    si_url, ss_url = discover(GBFS_URL, GBFS_LANG)
    log(f"  station_information  {si_url}")
    log(f"  station_status       {ss_url}")

    conn = psycopg.connect(dsn())
    keys = upsert_stations(conn, si_url)
    last_station_refresh = time.monotonic()

    total = cycles = 0
    started = time.monotonic()
    last_seen_poll = None

    while not STOP:
        cycle_start = time.monotonic()
        try:
            if cycle_start - last_station_refresh > STATION_REFRESH_SECONDS:
                keys = upsert_stations(conn, si_url)
                last_station_refresh = cycle_start

            written, skipped, polled_at, keys = poll_status(
                conn, ss_url, keys, si_url, last_seen_poll)
            cycles += 1

            if written == 0 and polled_at == last_seen_poll:
                # Not an error, and not silent: at a poll interval shorter than
                # the feed's ttl this is the normal case, and a reader deserves
                # to know why the row count is not moving.
                log(f"poll {cycles}: feed unchanged since {polled_at:%H:%M:%S}, nothing written")
            else:
                last_seen_poll = polled_at
                total += written
                note = f", {skipped} skipped" if skipped else ""
                log(f"poll {cycles}: {written} rows{note}, {total} total")
        except Exception as exc:                                   # noqa: BLE001
            # A transient 5xx from the CDN or a dropped connection should not
            # end a run that is meant to last for days.
            log(f"cycle failed ({type(exc).__name__}: {exc}) — retrying next cycle")
            try:
                conn.rollback()
            except Exception:                                      # noqa: BLE001
                conn = psycopg.connect(dsn())

        elapsed = time.monotonic() - cycle_start
        for _ in range(int(max(0.0, POLL_SECONDS - elapsed))):
            if STOP:
                break
            time.sleep(1)

    mins = (time.monotonic() - started) / 60
    log(f"stopped: {cycles} polls, {total} rows in {mins:.1f} min")
    conn.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Check everything the workshop needs before you start paying for cloud
# resources. Safe to run repeatedly.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
FAIL=0

echo
echo "Local tooling"
docker info >/dev/null 2>&1 && ok "Docker is running" || bad "Docker is not running"
docker compose version >/dev/null 2>&1 \
    && ok "Compose v2 ($(docker compose version --short 2>/dev/null))" \
    || bad "docker compose (v2) not found"
command -v curl >/dev/null && ok "curl" || bad "curl not found"

echo
echo "The data feed (public, no key)"
# A liveness probe from your laptop, not configuration. The workshop's real
# fetch is ClickHouse's, and its URL lives in clickhouse/01-ingest-rmv.sql.
# Override here only to check a different city before you commit to it.
GBFS_URL="${GBFS_URL:-https://gbfs.citibikenyc.com/gbfs/2.3/gbfs.json}"
if disco=$(curl -fsS --max-time 20 "$GBFS_URL" 2>/dev/null); then
    ok "auto-discovery reachable"
    ss=$(printf '%s' "$disco" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
feeds = d.get('en', d).get('feeds', [])
print(next((f['url'] for f in feeds if f['name'] == 'station_status'), ''))
" 2>/dev/null)
    if [ -n "$ss" ]; then
        n=$(curl -fsS --max-time 20 "$ss" | python3 -c \
            "import sys,json; print(len(json.load(sys.stdin)['data']['stations']))" 2>/dev/null)
        [ -n "$n" ] && ok "station_status: $n stations right now" \
                    || bad "station_status did not parse"
    else
        bad "station_status not advertised by this feed"
    fi
else
    bad "cannot reach $GBFS_URL"
fi

echo
echo "Managed Postgres"
if [ -f "$LAB_DIR/.env" ]; then
    ok ".env present"
    load_config
    if out=$(psql_run -tAc "SELECT current_setting('server_version')" 2>&1); then
        ok "connected — PostgreSQL $out"
        pg=$(psql_run -tAc \
            "SELECT count(*) FROM pg_available_extensions WHERE name='postgis'" 2>/dev/null)
        [ "$pg" = "1" ] && ok "postgis is available" || bad "postgis not available"

        # Ingestion is pg_cron pulling through pg_clickhouse, so both of these
        # are load-bearing from module 03 on — not just for the pushdown.
        cr=$(psql_run -tAc \
            "SELECT count(*) FROM pg_available_extensions WHERE name='pg_cron'" 2>/dev/null)
        [ "$cr" = "1" ] && ok "pg_cron is available" \
                        || bad "pg_cron not available — nothing would schedule the sync"

        ch=$(psql_run -tAc \
            "SELECT count(*) FROM pg_available_extensions WHERE name='pg_clickhouse'" 2>/dev/null)
        [ "$ch" = "1" ] && ok "pg_clickhouse is available" \
                        || bad "pg_clickhouse not available — modules 03 and 06 both need it"

        # Deliberately not checked: plperlu. It is in the catalogue and it
        # installs, but the server's Perl has no TLS stack, so it cannot fetch
        # an https feed. Module 03 covers that, and
        # sql/03-check-in-db-http.sql re-measures it on your own service.
        wal=$(psql_run -tAc "SELECT current_setting('wal_level')" 2>/dev/null)
        [ "$wal" = "logical" ] && ok "wal_level = logical (ClickPipes can replicate)" \
                               || warn "wal_level = $wal — ClickPipes needs 'logical'"
    else
        bad "cannot connect: $(printf '%s' "$out" | head -1 | mask)"
    fi
    echo
    echo "ClickHouse Cloud"
    # Needed from module 03, not from module 05: ClickHouse is what fetches the
    # feed, so an empty CH_HOST stops ingestion, not just the pushdown.
    if [ -n "${CH_HOST:-}" ] && [ -n "${CH_PASSWORD:-}" ]; then
        ok "CH_HOST and CH_PASSWORD are set"
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
            -u "${CH_USER:-default}:${CH_PASSWORD}" \
            "https://${CH_HOST}:${CH_PORT:-8443}/?query=SELECT+1" 2>/dev/null || true)
        case "$code" in
            200) ok "HTTPS interface answered SELECT 1" ;;
            401|403) bad "authentication refused (HTTP $code) — check CH_USER / CH_PASSWORD" ;;
            *)   bad "no answer from ${CH_HOST}:${CH_PORT:-8443} (HTTP ${code:-none})" ;;
        esac
    else
        bad "CH_HOST / CH_PASSWORD missing — module 03 cannot fetch the feed without them"
    fi
else
    warn "no .env yet — that is expected before module 01"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "Ready."
else
    echo "Fix the ✗ items above before continuing." >&2
    exit 1
fi

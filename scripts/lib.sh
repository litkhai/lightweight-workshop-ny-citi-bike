#!/usr/bin/env bash
# Shared helpers. Sourced by every script in this directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export LAB_DIR

# Only a client is needed here — PostGIS lives on the server, which is your
# Managed Postgres service. The plain postgres image is multi-arch (the
# postgis/postgis tags have no arm64 build, which breaks Apple Silicon) and a
# fraction of the size.
PSQL_IMAGE="${PSQL_IMAGE:-postgres:17-alpine}"

# clickhouse-client lives in the server image. There is a clickhouse/clickhouse-client
# repository, but it publishes no arm64 manifest, so it breaks on Apple Silicon
# exactly the way postgis/postgis does.
CH_IMAGE="${CH_IMAGE:-clickhouse/clickhouse-server:latest}"

load_config() {
    if [ -f "$LAB_DIR/.env" ]; then
        # shellcheck disable=SC1091
        set -a; . "$LAB_DIR/.env"; set +a
    fi
    local missing=()
    [ -n "${PGHOST:-}" ]     || missing+=(PGHOST)
    [ -n "${PGPASSWORD:-}" ] || missing+=(PGPASSWORD)
    if [ ${#missing[@]} -gt 0 ]; then
        cat >&2 <<EOF
missing: ${missing[*]}

Copy the template and fill in your Managed Postgres connection details:

    cp .env.example .env
    \$EDITOR .env

.env is gitignored. Never commit real endpoints or passwords.
EOF
        exit 1
    fi
    export PGHOST PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" \
           PGPASSWORD PGDATABASE="${PGDATABASE:-postgres}" \
           PGSSLMODE="${PGSSLMODE:-require}"
}

# Both hostnames carry the service name and id, and people screenshot their
# terminals during workshops. Mask them on the way out.
mask() {
    local sed_args=()
    [ -n "${PGHOST:-}" ] && sed_args+=(-e "s/${PGHOST//./\\.}/<your-service>.pg.clickhouse.cloud/g")
    [ -n "${CH_HOST:-}" ] && sed_args+=(-e "s/${CH_HOST//./\\.}/<your-service>.clickhouse.cloud/g")
    if [ ${#sed_args[@]} -eq 0 ]; then cat; else sed -E "${sed_args[@]}"; fi
}

# psql in a container, so nobody has to install a client. The sql/ directory is
# mounted at /sql, which is why every example says -f /sql/....
psql_run() {
    docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        -v "$LAB_DIR/sql:/sql:ro" \
        "$PSQL_IMAGE" psql "$@"
}

load_ch_config() {
    local missing=()
    [ -n "${CH_HOST:-}" ]     || missing+=(CH_HOST)
    [ -n "${CH_PASSWORD:-}" ] || missing+=(CH_PASSWORD)
    if [ ${#missing[@]} -gt 0 ]; then
        cat >&2 <<EOF
missing: ${missing[*]}

ClickHouse is what fetches the feed, so these are needed from module 03 on —
not just for the pushdown. Add them to .env (or re-run ./setup.sh).
EOF
        exit 1
    fi
    # The native protocol, not the 8443 HTTPS interface CH_PORT names: the client
    # speaks native, and it is the only way to send a file of several statements
    # in one go. HTTP executes exactly one statement per request.
    export CH_HOST CH_NATIVE_PORT="${CH_NATIVE_PORT:-9440}" \
           CH_USER="${CH_USER:-default}" CH_PASSWORD \
           CH_DATABASE="${CH_DATABASE:-default}"
}

# clickhouse-client in a container, for the same reason psql is. The client ships
# inside the server image; there is no separate multi-arch client image.
ch_run() {
    docker run --rm -i \
        -v "$LAB_DIR/clickhouse:/clickhouse:ro" \
        "$CH_IMAGE" clickhouse-client \
            --host "$CH_HOST" --port "$CH_NATIVE_PORT" --secure \
            --user "$CH_USER" --password "$CH_PASSWORD" "$@"
}

require_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo "Docker is not running. Start Docker Desktop and try again." >&2
        exit 1
    fi
}

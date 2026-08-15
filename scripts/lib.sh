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

# The hostname carries the service name and id, and people screenshot their
# terminals during workshops. Mask it on the way out.
mask() {
    sed -E "s/${PGHOST//./\\.}/<your-service>.pg.clickhouse.cloud/g"
}

# psql in a container, so nobody has to install a client. The sql/ directory is
# mounted at /sql, which is why every example says -f /sql/....
psql_run() {
    docker run --rm -i \
        -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
        -v "$LAB_DIR/sql:/sql:ro" \
        "$PSQL_IMAGE" psql "$@"
}

require_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo "Docker is not running. Start Docker Desktop and try again." >&2
        exit 1
    fi
}

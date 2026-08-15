#!/usr/bin/env bash
# Interactive setup. Asks for the two services you created in module 01 and
# writes .env.
#
#   ./setup.sh
#
# Everything it asks for is on the "Connect" screen of each service in
# console.clickhouse.cloud. Nothing is sent anywhere: the file is written
# locally, chmod 600, and .env is gitignored.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1" >&2; }

# ask <prompt> <default> <varname>
ask() {
    local prompt="$1" def="$2" __var="$3" reply
    if [ -n "$def" ]; then
        read -r -p "  $prompt [$def]: " reply
        reply="${reply:-$def}"
    else
        read -r -p "  $prompt: " reply
    fi
    printf -v "$__var" '%s' "$reply"
}

ask_secret() {
    local prompt="$1" __var="$2" reply
    read -r -s -p "  $prompt: " reply; echo
    printf -v "$__var" '%s' "$reply"
}

echo
bold "NY Citi Bike workshop — setup"
dim  "Both services are created in the console first; see workshop/01-provision.md."
echo

if [ -f "$ENV_FILE" ]; then
    red "$ENV_FILE already exists."
    read -r -p "  Overwrite it? [y/N]: " ow
    case "$ow" in [yY]*) ;; *) echo "  Left alone."; exit 0;; esac
    echo
fi

# --------------------------------------------------------------------------
bold "1/3  ClickHouse Managed Postgres"
dim  "     Console → Postgres → your service → Connect"
ask        "Host        (…aws.pg.clickhouse.cloud)" ""          PGHOST
ask        "Port"                                   "5432"      PGPORT
ask        "User"                                   "postgres"  PGUSER
ask_secret "Password"                                           PGPASSWORD
ask        "Database"                               "postgres"  PGDATABASE
echo

# --------------------------------------------------------------------------
bold "2/3  ClickHouse Cloud"
dim  "     Console → your service → Connect → HTTPS. Needed from module 04 on;"
dim  "     press Enter to skip and fill it in later."
ask        "Host        (…aws.clickhouse.cloud)"    ""          CH_HOST
ask        "Port"                                   "8443"      CH_PORT
ask        "User"                                   "default"   CH_USER
ask_secret "Password"                                           CH_PASSWORD
ask        "Database"                               "default"   CH_DATABASE
echo

# --------------------------------------------------------------------------
bold "3/3  The feed"
dim  "     Any docked system from the GBFS registry. Default is New York."
ask        "GBFS discovery URL" \
           "https://gbfs.citibikenyc.com/gbfs/2.3/gbfs.json"    GBFS_URL
ask        "Seconds between snapshots"              "60"        POLL_SECONDS
echo

# --------------------------------------------------------------------------
if [ -z "$PGHOST" ] || [ -z "$PGPASSWORD" ]; then
    red "PGHOST and the Postgres password are required — nothing was written."
    exit 1
fi

umask 077
cat > "$ENV_FILE" <<EOF
# Written by setup.sh. Gitignored — never commit this file.

# ClickHouse Managed Postgres
PGHOST=$PGHOST
PGPORT=$PGPORT
PGUSER=$PGUSER
PGPASSWORD=$PGPASSWORD
PGDATABASE=$PGDATABASE
PGSSLMODE=require

# ClickHouse Cloud
CH_HOST=$CH_HOST
CH_PORT=$CH_PORT
CH_USER=$CH_USER
CH_PASSWORD=$CH_PASSWORD
CH_DATABASE=$CH_DATABASE

# The feed
GBFS_URL=$GBFS_URL
GBFS_LANG=en
POLL_SECONDS=$POLL_SECONDS

# Dashboard. FOREIGN_SCHEMA stays empty until module 05 imports it.
LOCAL_SCHEMA=citibike
FOREIGN_SCHEMA=
UI_PORT=8080
EOF
chmod 600 "$ENV_FILE"
green "  wrote .env (mode 600)"
echo

# --------------------------------------------------------------------------
bold "Checking it"
if "$HERE/scripts/preflight.sh"; then
    echo
    green "Ready. Next: ./scripts/psql.sh -f /sql/01-schema.sql"
    dim   "Then  workshop/02-postgres-and-feed.md"
else
    echo
    red "Preflight reported problems — fix those before module 02."
    exit 1
fi

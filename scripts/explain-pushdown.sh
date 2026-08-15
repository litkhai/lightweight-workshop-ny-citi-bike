#!/usr/bin/env bash
# Did that query run on ClickHouse, or did the rows come back to be counted here?
#
#   ./scripts/explain-pushdown.sh "SELECT count(*) FROM ny_citibike_ch.station_status"
#   ./scripts/explain-pushdown.sh -f /sql/20-aggregate-pushdown.sql
#
# Reading the plan is the only honest answer. A fast query proves nothing:
# Postgres will happily pull millions of rows across the wire and count them
# locally, and the only visible difference is the plan.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_docker
load_config

if [ $# -eq 0 ]; then
    echo "usage: $0 <sql>" >&2
    exit 2
fi
SQL="$1"

PLAN=$(psql_run -tAc "EXPLAIN (VERBOSE, COSTS OFF) $SQL" 2>&1) || {
    printf '%s\n' "$PLAN" | mask >&2
    exit 1
}

echo "--- plan ---"
printf '%s\n' "$PLAN" | mask
echo
echo "--- verdict ---"

REMOTE=$(printf '%s' "$PLAN" | grep -i "Remote SQL" || true)

if [ -z "$REMOTE" ]; then
    FT=$(psql_run -tAc \
        "SELECT count(*) FROM information_schema.foreign_tables" 2>/dev/null || echo 0)
    if [ "${FT:-0}" -eq 0 ]; then
        echo "Postgres — no foreign tables are configured, so there is nothing"
        echo "to push down to. Run sql/40-fdw-clickhouse.sql first."
    else
        echo "Postgres — no foreign table appears in this plan. It read local tables."
    fi
    exit 0
fi

if printf '%s' "$REMOTE" | grep -qiE '\bGROUP BY\b|\bcount\(|\bsum\(|\bavg\(|\bmin\(|\bmax\('; then
    echo "ClickHouse — the remote SQL carries the aggregation."
    echo
    printf '%s\n' "$REMOTE" | mask
else
    echo "Postgres — the foreign scan selects columns only. Every row crossed"
    echo "the network to be counted here."
    echo
    echo "The usual cause is a local table in the join. Both ny_citibike.stations and"
    echo "ny_citibike.station_status have to be replicated for the join to stay remote."
    echo
    printf '%s\n' "$REMOTE" | mask
fi

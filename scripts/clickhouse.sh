#!/usr/bin/env bash
# clickhouse-client against your ClickHouse Cloud service, in a container.
#
#   ./scripts/clickhouse.sh                                   # interactive
#   ./scripts/clickhouse.sh -f /clickhouse/01-ingest-rmv.sql   # run a file
#   ./scripts/clickhouse.sh -q 'SELECT count() FROM ny_citibike.gbfs_status'
#
# The companion to scripts/psql.sh, and it exists for the same reason: nobody
# should have to install a client to do this workshop. `clickhouse/` is mounted
# at /clickhouse, which is why the example above says -f /clickhouse/....
#
# Why a client rather than curl: the HTTPS interface on 8443 executes exactly
# one statement per request, and clickhouse/01-ingest-rmv.sql is a dozen of
# them. The native protocol takes the whole file. That is also why this script
# uses port 9440 rather than the CH_PORT in your .env, which the dashboard and
# the FDW use for HTTPS.
#
# Output is masked so the hostname does not end up in a screenshot.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_docker
load_config
load_ch_config

if [ $# -eq 0 ]; then
    # Interactive needs a TTY and must not go through the masking pipe.
    docker run --rm -it \
        -v "$LAB_DIR/clickhouse:/clickhouse:ro" \
        "$CH_IMAGE" clickhouse-client \
            --host "$CH_HOST" --port "$CH_NATIVE_PORT" --secure \
            --user "$CH_USER" --password "$CH_PASSWORD"
    exit
fi

# `-f file` means --queries-file here, deliberately.
#
# In clickhouse-client `-f` is short for --format, so passing a filename to it
# silently sets the output format to a path and runs nothing at all — no error,
# no output. Since every other instruction in this workshop says `-f`, the flag
# is translated rather than left as a trap.
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--file) args+=(--queries-file "$2"); shift 2 ;;
        *)         args+=("$1"); shift ;;
    esac
done

# A file of many statements needs this; a single -q is unaffected by it.
ch_run --multiquery "${args[@]}" 2>&1 | mask

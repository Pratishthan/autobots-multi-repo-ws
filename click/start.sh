#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if pgrep -f "clickhouse server" > /dev/null; then
    echo "ClickHouse is already running (pid $(pgrep -f 'clickhouse server'))"
    exit 0
fi

echo "Starting ClickHouse..."
"$SCRIPT_DIR/clickhouse" server --config-file="$SCRIPT_DIR/config.xml" &> "$SCRIPT_DIR/data/clickhouse.log" &

sleep 1

if curl -sf http://localhost:8123/ping > /dev/null; then
    echo "ClickHouse started (pid $!)"
else
    echo "ClickHouse failed to start. Check $SCRIPT_DIR/data/clickhouse.log"
    exit 1
fi

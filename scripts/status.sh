#!/usr/bin/env bash
# Report ccserver process status.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="$ROOT/run/ccserver.pid"

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "ccserver running (pid $(cat "$PIDFILE"))"
else
    echo "ccserver not running"
    exit 1
fi

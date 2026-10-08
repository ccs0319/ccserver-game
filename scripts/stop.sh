#!/usr/bin/env bash
# Stop the ccserver process started by scripts/start.sh (pidfile based).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="$ROOT/run/ccserver.pid"

if [[ ! -f "$PIDFILE" ]]; then
    echo "ccserver not running (no pidfile)"
    exit 0
fi

PID="$(cat "$PIDFILE")"
if ! kill -0 "$PID" 2>/dev/null; then
    echo "stale pidfile (pid $PID not alive); removing"
    rm -f "$PIDFILE"
    exit 0
fi

kill "$PID"
for _ in $(seq 1 50); do
    if ! kill -0 "$PID" 2>/dev/null; then
        rm -f "$PIDFILE"
        echo "ccserver stopped (pid $PID)"
        exit 0
    fi
    sleep 0.1
done

echo "graceful stop timed out; sending SIGKILL (pid $PID)" >&2
kill -9 "$PID" 2>/dev/null || true
rm -f "$PIDFILE"
echo "ccserver killed (pid $PID)"

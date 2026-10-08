#!/usr/bin/env bash
# Start the ccserver binary in the background with a pidfile and logfile.
#
#   scripts/start.sh [bootstrap.lua]
#
# Overrides: CCS_BIN, CCS_BOOTSTRAP, CCS_LOG
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="${CCS_BIN:-$ROOT/target/release/moon_rs}"
BOOTSTRAP="${1:-${CCS_BOOTSTRAP:-assets/example/example_server.lua}}"
PIDFILE="$ROOT/run/ccserver.pid"
LOG="${CCS_LOG:-$ROOT/logs/ccserver.log}"

mkdir -p "$ROOT/run" "$(dirname "$LOG")"

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "ccserver already running (pid $(cat "$PIDFILE"))"
    exit 0
fi

if [[ ! -x "$BIN" ]]; then
    echo "binary not found: $BIN" >&2
    echo "build it first: make build" >&2
    exit 1
fi

nohup "$BIN" "$BOOTSTRAP" >>"$LOG" 2>&1 &
echo $! >"$PIDFILE"
echo "ccserver started (pid $(cat "$PIDFILE"))"
echo "  bootstrap: $BOOTSTRAP"
echo "  log:       $LOG"

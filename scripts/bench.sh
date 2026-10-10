#!/usr/bin/env bash
# One-shot gateway load test: start the server (high rate limit), run the
# benchmark client against it, then stop the server.
#
#   scripts/bench.sh
#
# Env: CONN (default 100), SEC (default 5), MSG (PING|MOVE), CCS_BENCH_ADDR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONN="${CONN:-100}"
SEC="${SEC:-5}"
MSG="${MSG:-PING}"
ADDR="${CCS_BENCH_ADDR:-127.0.0.1:9001}"

if [[ ! -x target/release/moon_rs ]]; then
    echo "building release binary..."
    cargo build --release -p moon-app
fi

echo "==> starting server (rate limit disabled)"
CCS_NODE_ID=1 \
CCS_GATEWAY_RATE=100000000 CCS_GATEWAY_BURST=100000000 \
    scripts/start.sh app/main.lua
sleep 2

trap 'scripts/stop.sh >/dev/null 2>&1 || true' EXIT

echo "==> running benchmark"
CCS_BENCH_ADDR="$ADDR" CCS_BENCH_CONN="$CONN" CCS_BENCH_SEC="$SEC" CCS_BENCH_MSG="$MSG" \
    ./target/release/moon_rs assets/benchmark/benchmark_gateway.lua

echo "==> stopping server"
scripts/stop.sh >/dev/null 2>&1 || true

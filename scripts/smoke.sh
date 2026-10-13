#!/usr/bin/env bash
# End-to-end smoke test: build, start the app, verify readiness, run a client
# flow (login/enter/move) against the gateway, then stop.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -x target/release/moon_rs ]]; then
    echo "building release binary..."
    cargo build --release -p moon-app
fi

CCS_NODE_ID=1 scripts/start.sh app/main.lua
trap 'scripts/stop.sh >/dev/null 2>&1 || true' EXIT
sleep 2

echo "==> readiness"
curl -fsS http://127.0.0.1:9002/ready && echo

echo "==> client flow"
CCS_BENCH_ADDR=127.0.0.1:9001 ./target/release/moon_rs assets/test/test_multinode.lua

echo "==> stopping"
scripts/stop.sh >/dev/null 2>&1 || true
echo "smoke OK"

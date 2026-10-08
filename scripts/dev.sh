#!/usr/bin/env bash
# One-click dev startup: bring up local dependencies, build, then run in the
# foreground with logs on stdout.
#
#   scripts/dev.sh [bootstrap.lua]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BOOTSTRAP="${1:-${CCS_BOOTSTRAP:-assets/example/example_server.lua}}"

echo "==> dependencies"
"$ROOT/scripts/db-up.sh"

echo "==> build (release)"
cargo build --release -p moon-app

echo "==> run $BOOTSTRAP"
exec "$ROOT/target/release/moon_rs" "$BOOTSTRAP"

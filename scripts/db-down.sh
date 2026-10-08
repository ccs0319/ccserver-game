#!/usr/bin/env bash
# Stop local development dependencies (keeps data volumes).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
docker compose down

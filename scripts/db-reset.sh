#!/usr/bin/env bash
# Stop local dependencies AND wipe their data volumes (destructive).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
docker compose down -v
echo "local database volumes removed"

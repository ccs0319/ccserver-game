#!/usr/bin/env bash
# Bring up local development dependencies (Redis / MySQL / PostgreSQL / MongoDB).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found; install Docker or start dependencies manually" >&2
    exit 1
fi

docker compose up -d
echo "waiting for services to become healthy..."
# `docker compose up -d --wait` blocks until healthchecks pass.
docker compose up -d --wait
docker compose ps

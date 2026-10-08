#!/usr/bin/env bash
# Restart ccserver (stop + start).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/stop.sh"
"$ROOT/scripts/start.sh" "$@"

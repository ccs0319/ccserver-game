#!/usr/bin/env bash
# Stop the local cluster started by scripts/run-cluster.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for name in node1 node2 discovery; do
    pidfile="$ROOT/run/$name.pid"
    if [[ -f "$pidfile" ]]; then
        pid="$(cat "$pidfile")"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            echo "stopped $name (pid $pid)"
        fi
        rm -f "$pidfile"
    fi
done

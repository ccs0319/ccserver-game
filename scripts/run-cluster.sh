#!/usr/bin/env bash
# Launch a 2-node cluster for local validation:
#   discovery (HTTP registry, :9090)
#   node 1  (gateway :9001, login, lobby, world_1, admin :9002)
#   node 2  (world_2)
#
# Uses app/config/topology.multinode.lua and app/config/node.json.
# Stop with scripts/stop-cluster.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="$ROOT/target/release/moon_rs"
if [[ ! -x "$BIN" ]]; then
    echo "building release binary..."
    cargo build --release -p moon-app
fi

mkdir -p run logs

# Discovery registry.
nohup "$BIN" assets/example/cluster/cluster_etc.lua "$ROOT/app/config/node.json" \
    >logs/discovery.log 2>&1 &
echo $! >run/discovery.pid
sleep 1

# Node 1.
CCS_NODE_ID=1 CCS_TOPOLOGY=config/topology.multinode.lua CCS_CLUSTER_LISTEN=1 \
    CCS_GATEWAY_ADDR=0.0.0.0:9001 CCS_ADMIN_ADDR=0.0.0.0:9002 \
    nohup "$BIN" app/main.lua >logs/node1.log 2>&1 &
echo $! >run/node1.pid

# Node 2.
CCS_NODE_ID=2 CCS_TOPOLOGY=config/topology.multinode.lua CCS_CLUSTER_LISTEN=1 \
    nohup "$BIN" app/main.lua >logs/node2.log 2>&1 &
echo $! >run/node2.pid

sleep 2
echo "cluster up: discovery(:9090) node1(gateway :9001) node2(world_2)"
echo "logs: logs/discovery.log logs/node1.log logs/node2.log"

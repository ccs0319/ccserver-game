#!/usr/bin/env bash
# Launch a 2-node cluster with **etcd** service discovery:
#   etcd (docker, :2379) + discovery adapter (:9090) + node1 (:9001) + node2 (world_2)
#
# Nodes register their cluster address in etcd with a lease; the adapter exposes
# etcd to the native cluster module. Stop with scripts/stop-cluster.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="$ROOT/target/release/moon_rs"
if [[ ! -x "$BIN" ]]; then
    echo "building release binary..."
    cargo build --release -p moon-app
fi

mkdir -p run logs

# etcd (start a local container if none is reachable).
if ! curl -s http://127.0.0.1:2379/health >/dev/null 2>&1; then
    echo "starting etcd (docker)..."
    docker rm -f ccs-etcd >/dev/null 2>&1 || true
    docker run -d --name ccs-etcd -p 2379:2379 quay.io/coreos/etcd:v3.5.0 \
        /usr/local/bin/etcd \
        --advertise-client-urls http://0.0.0.0:2379 \
        --listen-client-urls http://0.0.0.0:2379 >/dev/null
    sleep 3
fi

# Discovery adapter (etcd -> HTTP contract).
CCS_DISCOVERY_ADDR=0.0.0.0:9090 nohup "$BIN" app/discovery.lua >logs/discovery.log 2>&1 &
echo $! >run/discovery.pid
sleep 2

# Node 1.
CCS_NODE_ID=1 CCS_TOPOLOGY=config/topology.etcd.lua CCS_CLUSTER_ADDR=127.0.0.1:42345 \
    CCS_CLUSTER_LISTEN=1 CCS_GATEWAY_ADDR=0.0.0.0:9001 CCS_ADMIN_ADDR=0.0.0.0:9002 \
    nohup "$BIN" app/main.lua >logs/node1.log 2>&1 &
echo $! >run/node1.pid

# Node 2.
CCS_NODE_ID=2 CCS_TOPOLOGY=config/topology.etcd.lua CCS_CLUSTER_ADDR=127.0.0.1:42346 \
    CCS_CLUSTER_LISTEN=1 nohup "$BIN" app/main.lua >logs/node2.log 2>&1 &
echo $! >run/node2.pid

sleep 2
echo "etcd cluster up: etcd(:2379) discovery(:9090) node1(gateway :9001) node2(world_2)"
echo "registered nodes: $(curl -s http://127.0.0.1:9090/nodes)"

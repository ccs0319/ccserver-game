# Service Discovery

ccserver resolves node addresses through an HTTP discovery contract baked into
the cluster module:

```
GET <discovery_url>   (with {} replaced by the target node id)  ->  "host:port"
```

Two backends:

| Mode | Registry | Use |
| --- | --- | --- |
| Dev / static | `assets/example/cluster/cluster_etc.lua` + `node.json` | single host, fixed addresses |
| **Production** | **etcd** (v3) + `app/discovery.lua` adapter | dynamic, self-healing |

## etcd-backed discovery

```
        register (lease + keepalive)          read (GET /cluster?node=N)
 node ───────────────────────────▶ etcd ◀────────────────────── discovery adapter ──▶ node
 (gRPC, etcd client)                                          (HTTP, cluster contract)
```

- **Nodes** connect to etcd over gRPC (`ccserver.discovery` → `moon.db.etcd`),
  register `<prefix><node_id> = host:port` with a **lease**, and keep it alive
  (`lease_keep_alive`). When a node dies its keep-alive stops, the lease expires,
  and etcd removes the key — **dead nodes auto-deregister** (verified).
- The **adapter** (`app/discovery.lua`) reads etcd and answers the cluster
  module's `GET /cluster?node=N`. It is read-only w.r.t. etcd.

### Running locally

```bash
scripts/run-cluster-etcd.sh      # docker etcd(:2379) + adapter(:9090) + node1 + node2
# or: make cluster-etcd-up
curl localhost:9090/nodes        # {"1":"127.0.0.1:42345","2":"127.0.0.1:42346"}
CCS_BENCH_ADDR=127.0.0.1:9001 ./target/release/moon_rs assets/test/test_multinode.lua
scripts/stop-cluster.sh
# or one-shot: make test-multinode-etcd
```

### Configuration

Topology (`app/config/topology.etcd.lua`):

```lua
cluster = {
    discovery_url = "http://127.0.0.1:9090/cluster?node={}",  -- adapter
    listen = true,
    etcd = { endpoint = "http://127.0.0.1:2379", prefix = "/ccserver/nodes/", ttl = 10 },
}
```

Per-node env: `CCS_CLUSTER_ADDR` (this node's cluster `host:port`),
`CCS_CLUSTER_LISTEN=1`. Adapter env: `CCS_ETCD_ENDPOINT`, `CCS_ETCD_PREFIX`,
`CCS_ETCD_TTL`, `CCS_DISCOVERY_ADDR`, `CCS_ETCD_PROTO` (descriptor path).

The etcd gRPC descriptor is `assets/example/grpc/etcd.pb`; `ccserver.discovery`
auto-discovers it from common working directories (override with `CCS_ETCD_PROTO`).

### Verified

- `make test-multinode-etcd`: zone-2 requests from node 1's gateway are served by
  `world_2` on node 2 (cross-node, etcd discovery).
- Lease expiry: after stopping node 2 and waiting the TTL, `/nodes` no longer
  lists node 2 while node 1 remains.

## Notes / follow-ups

- The adapter is a single process; run it redundantly (or behind a VIP) in
  production. etcd itself should be a multi-member cluster.
- Nodes could also read etcd directly for peer discovery if the native cluster
  module ever gains a non-HTTP discovery hook (avoids the adapter).
- The static HTTP registry remains the zero-dependency default for dev.

## Files

| Path | Role |
| --- | --- |
| `lualib/ccserver/discovery.lua` | etcd registry (register/resolve/keepalive) + HTTP adapter |
| `app/discovery.lua` | standalone adapter process |
| `app/config/topology.etcd.lua` | 2-node topology with etcd discovery |
| `scripts/run-cluster-etcd.sh` | start etcd + adapter + nodes |
| `assets/test/test_multinode.lua` | cross-node routing check |

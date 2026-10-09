# ccserver Architecture

> Status: **M1 (service topology skeleton) implemented.** This document is the
> authoritative description of the target architecture and how the current code
> maps to it. Update it whenever service boundaries or the topology change.

## Process model

- **One `moon_rs` binary = one OS process = one cluster node.**
- Inside a node: a Tokio multi-thread runtime plus dedicated OS threads for
  `unique` actors (each `unique` service owns its thread).
- **Cross-process / multi-node** communication uses the `cluster` module: nodes
  address services by `(node_id, service_name)` over TCP with a discovery
  registry. This is how you scale beyond one process.

## Service topology

A mature deployment splits the game server into services with clear
responsibilities. The reference implementation ships four:

| Service | Responsibility | State | Scaling |
| --- | --- | --- | --- |
| **gateway** | client connections, framing, validation, rate limiting, session binding; forwards to backend services. Holds **no** secrets. | session index | horizontal |
| **login** | account auth, token issuance/verification, third-party SDKs. The **only** service holding auth secrets. | accounts | horizontal |
| **lobby** | profile, friends, matchmaking, chat. | mostly stateless | horizontal |
| **world** | in-game state per zone/line: entities, movement, AOI (`moon-game` crate). | stateful | sharded (`world_1..N`) |

```
Client ──TCP/KCP/WS──▶ gateway ──▶ login (auth, token)
                          │  verify token
                          ├──▶ lobby (profile/friends/match)
                          └──▶ world-N (zone/line, AOI/rooms)
                    cluster RPC  ▲  ▼  etcd/HTTP discovery
                data: moon.db (Redis / MySQL / PostgreSQL / Mongo)
```

**Rule of thumb:** split when a service has a different *scaling profile*,
*failure domain*, *deploy cadence*, or *security boundary*. Login is separated
for security + independent scaling; world is separated/sharded because it is
stateful. In dev you may co-locate all services in one process; the topology
config decides, so no code changes are needed to split later.

## Code layout

```
lualib/ccserver/            # framework layer
  service.lua               # service base: command dispatch + lifecycle
  router.lua                # local-first service routing (name -> node)
  topology.lua              # topology load/validate/plan
  node.lua                  # node bootstrap: cluster + spawn services
  services/                 # reference services (gateway/login/lobby/world)
app/                        # reference application
  main.lua                  # entry: node.start(topology, node_id)
  config/topology.lua       # which service runs on which node
```

## Topology config

```lua
return {
  cluster = {
    enabled = true,
    discovery_url = "http://127.0.0.1:2379/cluster?node={}",  -- {} = target node id
    listen = false,        -- true to accept inbound cluster connections
  },
  services = {
    gateway = { source = "ccserver.services.gateway", unique = true },
    login   = { source = "ccserver.services.login",   unique = true },
    lobby   = { source = "ccserver.services.lobby",   unique = true },
    world   = { source = "ccserver.services.world",   unique = true },
  },
  nodes = {
    [1] = { services = { "gateway", "login", "lobby", "world" } },
    -- [2] = { services = { "world" } },   -- multi-node: split world out
  },
}
```

- `services` is the catalog (`source` is a Lua module name or a `.lua` path).
- `nodes` assigns services to processes; `service_nodes` derives the routing map.
- Services must be `unique = true` to be addressable by name (needed for
  `cluster` routing and `moon.query`).

## Running

```bash
# single node (dev): everything in one process, no registry needed
CCS_NODE_ID=1 cargo run --release -- app/main.lua 1
# or via scripts:
CCS_NODE_ID=1 scripts/start.sh app/main.lua
```

Multi-node requires a discovery registry that maps `node_id -> host:port`. Any
HTTP endpoint works (see `assets/example/cluster/cluster_etc.lua`); etcd is the
production choice (`lualib/moon/db/etcd.lua`). Set `CCS_CLUSTER_LISTEN=1` on each
node and point `CCS_DISCOVERY_URL` at the registry.

## Service framework API

A service script calls the base (forwarding its params table):

```lua
local service = require("ccserver.service")
local router  = require("ccserver.router")

local commands = {}
function commands.echo(self, ...) return ... end

service.run({
  name = "my_service",
  commands = commands,
  on_start = function(self) end,
  on_stop  = function(self) end,
}, ...)
```

- `commands[cmd]` is invoked as `handler(self, ...)`; it may yield (call other
  services) and return any values.
- Errors are caught and returned to the caller as `false, errmsg` (a failing
  handler never leaves an RPC caller hanging).
- Route to other services by logical name; the router decides local vs remote:
  ```lua
  local ok, res = router.call("login", "verify", token)
  router.send("world", "broadcast", msg)
  ```

## Maturity roadmap

| Phase | Scope | Status |
| --- | --- | --- |
| **M1** | service topology skeleton (gateway/login/lobby/world, node, router, topology) | **done** |
| **M2** | unified frame protocol + version negotiation + login token + gateway session + 顶号/reconnect (see `docs/protocol.md`) | **done** |
| M3 | harden db/config/migration/hotreload (validation, locks, event-driven, broadcast) | planned |
| M4 | observability: metrics (Prometheus), health/readiness, tracing ids | planned |
| M5 | reliability & security: rate limit, circuit breaker, graceful drain, secrets, scheduled+verified backups | planned |
| M6 | CI/CD + load testing | planned |

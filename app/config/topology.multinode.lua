--- ccserver multi-node topology (2 nodes).
---
---   node 1: gateway, login, lobby, world_1 (zone 1), admin
---   node 2: world_2 (zone 2)
---
--- The gateway on node 1 routes zone-2 players to world_2 on node 2 over the
--- cluster. Requires a discovery registry mapping node id -> cluster address
--- (see app/config/node.json + assets/example/cluster/cluster_etc.lua), and
--- CCS_CLUSTER_LISTEN=1 on every node.
---
--- Launch with scripts/run-cluster.sh.

local function env(name, default)
    return os.getenv(name) or default
end

return {
    cluster = {
        enabled = true,
        discovery_url = env("CCS_DISCOVERY_URL", "http://127.0.0.1:9090/cluster?node={}"),
        listen = true,
    },

    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = {
            addr = env("CCS_GATEWAY_ADDR", "0.0.0.0:9001"),
            worlds = { [1] = "world_1", [2] = "world_2" },
        } },
        login   = { source = "ccserver.services.login",   unique = true },
        lobby   = { source = "ccserver.services.lobby",   unique = true },
        world_1 = { source = "ccserver.services.world",   unique = true, config = { zone = 1 } },
        world_2 = { source = "ccserver.services.world",   unique = true, config = { zone = 2 } },
        admin   = { source = "ccserver.services.admin",   unique = true, config = {
            addr = env("CCS_ADMIN_ADDR", "0.0.0.0:9002"),
            required_services = { "gateway", "login", "lobby" },
        } },
    },

    nodes = {
        [1] = { services = { "gateway", "login", "lobby", "world_1", "admin" } },
        [2] = { services = { "world_2" } },
    },
}

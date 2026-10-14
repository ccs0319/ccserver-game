--- ccserver reference topology.
---
--- Defines the service catalog and which node hosts which service. Copy and
--- adapt this file for a real deployment. Environment overrides:
---   CCS_CLUSTER=0            disable cluster (local-only routing)
---   CCS_CLUSTER_LISTEN=1     accept inbound cluster connections (multi-node)
---   CCS_DISCOVERY_URL=...    discovery endpoint, `{}` = target node id
---   CCS_NODE_ID=...          default node id when not passed as an arg

local function env(name, default)
    return os.getenv(name) or default
end

return {
    -- Client wire-protocol payload codec: "seri" (default) | "json" | "raw".
    -- Keep the client SDK in sync (see sdk/ccsclient).
    protocol = { codec = env("CCS_PROTOCOL_CODEC", "seri") },

    cluster = {
        enabled = env("CCS_CLUSTER", "1") ~= "0",
        discovery_url = env("CCS_DISCOVERY_URL", "http://127.0.0.1:2379/cluster?node={}"),
        listen = env("CCS_CLUSTER_LISTEN", "0") == "1",
    },

    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = {
            addr = env("CCS_GATEWAY_ADDR", "0.0.0.0:9001"),
            ws_addr = env("CCS_GATEWAY_WS_ADDR", "0.0.0.0:9011"),
            worlds = { [1] = "world_1", [2] = "world_2" },
            session = { redis_url = env("CCS_REDIS_URL", "redis://127.0.0.1:6379/0") },
        } },
        login   = { source = "ccserver.services.login",   unique = true },
        lobby_1 = { source = "ccserver.services.lobby",   unique = true,
                    client = { get = "get", leave = "leave" } },
        lobby_2 = { source = "ccserver.services.lobby",   unique = true },
        world_1 = { source = "ccserver.services.world",   unique = true, config = { zone = 1 } },
        world_2 = { source = "ccserver.services.world",   unique = true, config = { zone = 2 } },
        admin   = { source = "ccserver.services.admin",   unique = true, config = {
            addr = env("CCS_ADMIN_ADDR", "0.0.0.0:9002"),
            required_services = { "gateway", "login", "lobby_1", "lobby_2", "world_1", "world_2" },
        } },
    },

    -- Multiple instances of a logical service: round-robin + failover.
    groups = {
        lobby = { "lobby_1", "lobby_2" },
    },

    nodes = {
        -- Single-node dev: all shards/instances on node 1.
        [1] = { services = { "gateway", "login", "lobby_1", "lobby_2", "world_1", "world_2", "admin" } },

        -- Multi-node example: move world_2 to node 2 (set CCS_CLUSTER_LISTEN=1
        -- on each node, point CCS_DISCOVERY_URL at your registry, and use
        -- app/config/topology.multinode.lua).
    },
}

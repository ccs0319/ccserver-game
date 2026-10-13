--- ccserver multi-node topology using **etcd** service discovery.
---
---   node 1: gateway, login, lobby, world_1 (zone 1), admin
---   node 2: world_2 (zone 2)
---
--- Each node registers its cluster address in etcd (lease + keepalive) and
--- resolves peers through the discovery adapter (app/discovery.lua). Set
--- CCS_CLUSTER_ADDR per node and CCS_CLUSTER_LISTEN=1.
---
--- Launch with scripts/run-cluster-etcd.sh.

local function env(name, default)
    return os.getenv(name) or default
end

return {
    cluster = {
        enabled = true,
        -- HTTP adapter (app/discovery.lua) translating etcd -> host:port.
        discovery_url = env("CCS_DISCOVERY_URL", "http://127.0.0.1:9090/cluster?node={}"),
        listen = true,
        etcd = {
            endpoint = env("CCS_ETCD_ENDPOINT", "http://127.0.0.1:2379"),
            prefix = env("CCS_ETCD_PREFIX", "/ccserver/nodes/"),
            ttl = tonumber(env("CCS_ETCD_TTL", "10")),
        },
    },

    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = {
            addr = env("CCS_GATEWAY_ADDR", "0.0.0.0:9001"),
            worlds = { [1] = "world_1", [2] = "world_2" },
        } },
        login   = { source = "ccserver.services.login",   unique = true },
        lobby_1 = { source = "ccserver.services.lobby",   unique = true },
        lobby_2 = { source = "ccserver.services.lobby",   unique = true },
        world_1 = { source = "ccserver.services.world",   unique = true, config = { zone = 1 } },
        world_2 = { source = "ccserver.services.world",   unique = true, config = { zone = 2 } },
        admin   = { source = "ccserver.services.admin",   unique = true, config = {
            addr = env("CCS_ADMIN_ADDR", "0.0.0.0:9002"),
            required_services = { "gateway", "login", "lobby_1", "lobby_2" },
        } },
    },

    groups = {
        lobby = { "lobby_1", "lobby_2" },
    },

    nodes = {
        [1] = { services = { "gateway", "login", "lobby_1", "lobby_2", "world_1", "admin" } },
        [2] = { services = { "world_2" } },
    },
}

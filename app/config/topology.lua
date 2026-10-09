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
    cluster = {
        enabled = env("CCS_CLUSTER", "1") ~= "0",
        discovery_url = env("CCS_DISCOVERY_URL", "http://127.0.0.1:2379/cluster?node={}"),
        listen = env("CCS_CLUSTER_LISTEN", "0") == "1",
    },

    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = { addr = env("CCS_GATEWAY_ADDR", "0.0.0.0:9001") } },
        login   = { source = "ccserver.services.login",   unique = true },
        lobby   = { source = "ccserver.services.lobby",   unique = true },
        world   = { source = "ccserver.services.world",   unique = true },
        admin   = { source = "ccserver.services.admin",   unique = true, config = {
            addr = env("CCS_ADMIN_ADDR", "0.0.0.0:9002"),
            required_services = { "gateway", "login", "lobby", "world" },
        } },
    },

    nodes = {
        -- Single-node dev: everything on node 1.
        [1] = { services = { "gateway", "login", "lobby", "world", "admin" } },

        -- Multi-node example (set CCS_CLUSTER_LISTEN=1 on each node and point
        -- CCS_DISCOVERY_URL at your registry):
        -- [2] = { services = { "world" } },
    },
}

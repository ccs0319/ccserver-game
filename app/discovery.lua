--- Standalone etcd-backed discovery adapter.
---
--- Bridges etcd (the source of truth, written by nodes with leases) to the
--- native cluster module's HTTP discovery contract:
---   GET /cluster?node=N  -> host:port
---   GET /nodes           -> JSON { node_id: addr }
---
--- Run:  moon_rs app/discovery.lua
--- Env:  CCS_ETCD_ENDPOINT (http://127.0.0.1:2379), CCS_ETCD_PREFIX
---       (/ccserver/nodes/), CCS_ETCD_TTL (10), CCS_DISCOVERY_ADDR (0.0.0.0:9090)

local moon = require("moon")
local discovery = require("ccserver.discovery")

moon.loglevel("INFO")

local function env(name, default)
    return os.getenv(name) or default
end

moon.async(function()
    local reg, err = discovery.registry({
        endpoint = env("CCS_ETCD_ENDPOINT", "http://127.0.0.1:2379"),
        prefix = env("CCS_ETCD_PREFIX", "/ccserver/nodes/"),
        ttl = tonumber(env("CCS_ETCD_TTL", "10")),
        proto = env("CCS_ETCD_PROTO"),
    })
    if not reg then
        moon.error("discovery: etcd connect failed: " .. tostring(err))
        moon.exit(1)
        return
    end
    discovery.serve(reg, env("CCS_DISCOVERY_ADDR", "0.0.0.0:9090"))
    moon.info("discovery adapter ready")
end)

moon.shutdown(function()
    moon.quit()
end)

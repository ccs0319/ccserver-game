--- ccserver node bootstrap.
---
--- Starts one process (= one cluster node) from a topology config: initializes
--- the cluster (if enabled), configures the router, and spawns the services
--- assigned to this node. Call from an `moon.async` block in the app entry.
---
--- ```lua
--- local moon = require("moon")
--- local node = require("ccserver.node")
--- local topology = require("ccserver.topology")
--- moon.async(function()
---   node.start(topology.load("config/topology.lua"), 1)
--- end)
--- moon.shutdown(function() node.stop() end)
--- ```

local moon = require("moon")
local router = require("ccserver.router")
local topology = require("ccserver.topology")

local M = {}

--- Resolve a service source: a module name (dotted) via `package.path`, or a
--- literal `.lua` path passed through unchanged.
local function resolve_source(source)
    if source:find("/", 1, true) or source:find("%.lua$") then
        return source
    end
    local path = package.searchpath(source, package.path)
    return path or source
end

--- Start this node. Must be called inside `moon.async`.
---@param cfg table topology config (see `ccserver.topology`)
---@param node_id integer this process's node id
---@return table<string, integer> service name -> actor id
function M.start(cfg, node_id)
    local plan = topology.for_node(cfg, node_id)
    local cl = plan.cluster or {}
    local enabled = cl.enabled ~= false

    if enabled then
        local cluster = require("moon.cluster")
        if not cluster.init(node_id, cl.discovery_url or "") then
            error("ccserver.node: cluster.init failed")
        end
        if cl.listen then
            cluster.listen()
        end
    end

    local routing = topology.service_nodes(cfg)
    router.configure({ node_id = node_id, services = routing })

    local handles = {}
    for _, spec in ipairs(plan.services) do
        local id = moon.new_service({
            name = spec.name,
            source = resolve_source(spec.source),
            unique = spec.unique ~= false,
            node = node_id,
            service = spec.name,
            routing = routing,
            config = spec.config,
        })
        if not id or id == 0 then
            error(string.format("ccserver.node: failed to start service '%s'", spec.name))
        end
        handles[spec.name] = id
        moon.info(string.format("node %d: service '%s' started (id=%s)", node_id, spec.name, tostring(id)))
    end

    return handles
end

--- Look up a local unique service id by name.
---@param name string
---@return integer
function M.query(name)
    return moon.query(name)
end

--- Gracefully stop the node (services receive the shutdown signal separately).
function M.stop()
    local ok, cluster = pcall(require, "moon.cluster")
    if ok then
        pcall(cluster.shutdown)
    end
    moon.quit()
end

return M

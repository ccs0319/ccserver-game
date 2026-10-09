--- ccserver topology loader.
---
--- A topology describes which logical services run on which node. It is the
--- single source of truth for both local startup and cross-node routing.
---
--- ```lua
--- return {
---   cluster = {
---     enabled = true,
---     discovery_url = "http://127.0.0.1:2379/cluster?node={}",
---     listen = false,  -- true for multi-node (accept inbound cluster conns)
---   },
---   services = {
---     gateway = { source = "ccserver.services.gateway", unique = true },
---     login   = { source = "ccserver.services.login",   unique = true },
---     lobby   = { source = "ccserver.services.lobby",   unique = true },
---     world   = { source = "ccserver.services.world",   unique = true },
---   },
---   nodes = {
---     [1] = { services = { "gateway", "login", "lobby", "world" } },
---     [2] = { services = { "world" } },
---   },
--- }
--- ```

local M = {}

local function read(path)
    local ext = path:match("%.([%a%d]+)$")
    if ext == "lua" then
        return assert(load(io.readfile(path), "@" .. path))()
    elseif ext == "json" then
        return require("json").decode(io.readfile(path))
    end
    error("ccserver.topology: unsupported file type: " .. path)
end

--- Validate a topology table; raises on the first problem.
---@param cfg table
---@return table cfg
function M.validate(cfg)
    assert(type(cfg) == "table", "ccserver.topology: topology must be a table")
    assert(type(cfg.services) == "table", "ccserver.topology: `services` required")
    assert(type(cfg.nodes) == "table", "ccserver.topology: `nodes` required")

    for name, spec in pairs(cfg.services) do
        assert(type(spec.source) == "string",
            string.format("ccserver.topology: service '%s' requires `source`", tostring(name)))
    end

    for node, nd in pairs(cfg.nodes) do
        assert(type(nd.services) == "table",
            string.format("ccserver.topology: node %s requires a `services` list", tostring(node)))
        for _, sname in ipairs(nd.services) do
            assert(cfg.services[sname],
                string.format("ccserver.topology: node %s references unknown service '%s'", tostring(node), tostring(sname)))
        end
    end
    return cfg
end

--- Load and validate a topology file (`.lua` or `.json`).
---@param path string
---@return table
function M.load(path)
    return M.validate(read(path))
end

--- Build the routing map `service_name -> node_id`.
---@param cfg table
---@return table<string, integer>
function M.service_nodes(cfg)
    local map = {}
    for node, nd in pairs(cfg.nodes) do
        for _, sname in ipairs(nd.services) do
            if map[sname] and map[sname] ~= node then
                error(string.format("ccserver.topology: service '%s' is declared on multiple nodes", tostring(sname)))
            end
            map[sname] = node
        end
    end
    return map
end

--- Resolve the startup plan for one node.
---@param cfg table
---@param node_id integer
---@return table `{ services = { { name, source, unique } }, cluster = table }`
function M.for_node(cfg, node_id)
    local nd = cfg.nodes[node_id]
    if not nd then
        error(string.format("ccserver.topology: node %s is not defined", tostring(node_id)))
    end
    local services = {}
    for _, sname in ipairs(nd.services) do
        local spec = cfg.services[sname]
        services[#services + 1] = {
            name = sname,
            source = spec.source,
            unique = spec.unique,
            config = spec.config,
        }
    end
    return { services = services, cluster = cfg.cluster or {} }
end

return M

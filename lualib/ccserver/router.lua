--- ccserver service router.
---
--- Resolves a logical service name to its hosting node and dispatches with the
--- same call/send semantics whether the target is local or remote. This keeps
--- service code independent of the deployment topology: moving a service to
--- another node is a config change, not a code change.
---
--- Routing is **local-first**: if the target service is hosted on this node the
--- message goes straight through `moon.call`/`moon.send` (no cluster dependency);
--- only genuinely remote targets go through `cluster.call`/`cluster.send`. This
--- matters because each service is its own actor with its own Lua state, so the
--- cluster module's per-state `NODE` value cannot be relied on.
---
--- Configure per actor at startup (see `ccserver.node` / `ccserver.service`):
--- ```lua
--- router.configure({ node_id = 1, services = { login = 1, world = 2 } })
--- router.call("login", "verify", token)
--- ```

local moon = require("moon")

local M = {}

local node_id
local services = {}

local function cluster_mod()
    if not M._cluster then
        M._cluster = require("moon.cluster")
    end
    return M._cluster
end

---@param opts table `{ node_id, services }`
function M.configure(opts)
    opts = opts or {}
    node_id = opts.node_id
    services = opts.services or {}
end

---@param name string
---@param node integer
function M.register(name, node)
    services[name] = node
end

---@param map table<string, integer>
function M.register_all(map)
    for name, node in pairs(map or {}) do
        services[name] = node
    end
end

---@param name string
---@return integer|nil
function M.node_of(name)
    return services[name]
end

--- All known services (`name -> node`).
---@return table<string, integer>
function M.services()
    return services
end

---@return integer|nil
function M.self_node()
    return node_id
end

local function is_local(name)
    local node = services[name]
    if node == nil then
        error("ccserver.router: unknown service '" .. tostring(name) .. "'")
    end
    return node == node_id, node
end

local function local_addr(name)
    local addr = moon.query(name)
    if addr == 0 then
        error("ccserver.router: local service not found: " .. tostring(name))
    end
    return addr
end

--- Fire-and-forget message to a service by logical name.
---@param name string
---@param ... any
function M.send(name, ...)
    local local_target = is_local(name)
    if local_target then
        return moon.send("lua", local_addr(name), ...)
    end
    return cluster_mod().send(services[name], name, ...)
end

--- RPC call to a service by logical name (yields the caller coroutine).
---@async
---@param name string
---@param ... any
---@return any ...
function M.call(name, ...)
    local local_target = is_local(name)
    if local_target then
        return moon.call("lua", local_addr(name), ...)
    end
    return cluster_mod().call(services[name], name, ...)
end

return M

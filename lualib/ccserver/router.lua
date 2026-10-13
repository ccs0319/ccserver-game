--- ccserver service router.
---
--- Resolves a logical service name to its hosting node and dispatches with the
--- same call/send semantics whether the target is local or remote. This keeps
--- service code independent of the deployment topology: moving a service to
--- another node is a config change, not a code change.
---
--- Routing is **local-first**: if the target service is hosted on this node the
--- message goes straight through `moon.call`/`moon.send` (no cluster dependency);
--- only genuinely remote targets go through `cluster.call`/`cluster.send`.
---
--- **Service groups** (multiple instances of one logical service) round-robin
--- across instances and fail over on error, with a per-instance circuit breaker:
---
---   router.configure({ node_id = 1,
---     services = { lobby_1 = 1, lobby_2 = 1 },
---     groups   = { lobby = { "lobby_1", "lobby_2" } } })
---   router.call("lobby", "enter", uid)   -- -> lobby_1 or lobby_2, failover if down
---
--- Configure per actor at startup (see `ccserver.node` / `ccserver.service`).

local moon = require("moon")
local breaker = require("ccserver.breaker")

local M = {}

local node_id
local services = {}
local groups = {}
local group_cursor = {}

local function cluster_mod()
    if not M._cluster then
        M._cluster = require("moon.cluster")
    end
    return M._cluster
end

---@param opts table `{ node_id, services, groups }`
function M.configure(opts)
    opts = opts or {}
    node_id = opts.node_id
    services = opts.services or {}
    groups = opts.groups or {}
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
---@param node integer
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

local function local_addr(name)
    local addr = moon.query(name)
    if addr == 0 then
        error("ccserver.router: local service not found: " .. tostring(name))
    end
    return addr
end

-- Single-service dispatch (local-first).
local function call_single(name, ...)
    if services[name] == nil then
        error("ccserver.router: unknown service '" .. tostring(name) .. "'")
    end
    if services[name] == node_id then
        return moon.call("lua", local_addr(name), ...)
    end
    return cluster_mod().call(services[name], name, ...)
end

local function send_single(name, ...)
    if services[name] == nil then
        error("ccserver.router: unknown service '" .. tostring(name) .. "'")
    end
    if services[name] == node_id then
        return moon.send("lua", local_addr(name), ...)
    end
    return cluster_mod().send(services[name], name, ...)
end

-- Call one instance guarded by its circuit breaker; returns the instance's
-- values, or `false, err` on failure (error / breaker open / handler failure).
local function call_instance(inst, ...)
    if not breaker.allow(inst) then
        return false, "circuit open: " .. tostring(inst)
    end
    local r = table.pack(pcall(call_single, inst, ...))
    if not r[1] then
        breaker.record_failure(inst)
        return false, r[2]
    end
    if r[2] ~= false then
        breaker.record_success(inst)
    else
        breaker.record_failure(inst)
    end
    return table.unpack(r, 2, r.n)
end

--- RPC call to a service (or a group of instances) by logical name.
--- For a group: round-robin across instances and fail over to the next instance
--- on failure. Handlers must be safe to retry (idempotent) or tolerate it.
---@async
---@param name string
---@param ... any
---@return any ...
function M.call(name, ...)
    local instances = groups[name]
    if not instances or #instances == 0 then
        return call_single(name, ...)
    end
    local n = #instances
    local start = (group_cursor[name] or 0) % n + 1
    group_cursor[name] = start
    local last_err
    for i = 0, n - 1 do
        local inst = instances[(start - 1 + i) % n + 1]
        local r = table.pack(call_instance(inst, ...))
        if r[1] ~= false then
            return table.unpack(r, 1, r.n)
        end
        last_err = r[2]
    end
    return false, last_err or ("all instances of '" .. tostring(name) .. "' failed")
end

--- Fire-and-forget message to a service (or one round-robin group instance).
---@param name string
---@param ... any
function M.send(name, ...)
    local instances = groups[name]
    if instances and #instances > 0 then
        local n = #instances
        local idx = (group_cursor[name] or 0) % n + 1
        group_cursor[name] = idx
        return send_single(instances[idx], ...)
    end
    return send_single(name, ...)
end

return M

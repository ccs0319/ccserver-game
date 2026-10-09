--- ccserver service base.
---
--- A ccserver *service* is a moon_rs actor. Each service script calls
--- `service.run(spec, ...)` (forwarding its params table) and this base installs
--- a typed command dispatcher plus lifecycle hooks.
---
--- Commands are invoked as `service:command(...)`:
---   * request/response (session ~= 0) via `cluster.call(node, name, cmd, ...)`
---   * fire-and-forget (session == 0) via `cluster.send(node, name, cmd, ...)`
---
--- Handlers may yield (call other services) and return any Lua value. On error
--- the base replies `(false, errmsg)` to callers and logs the traceback, so a
--- failing handler never leaves an RPC caller hanging.

local moon = require("moon")
local router = require("ccserver.router")

local M = {}

local Service = {}
Service.__index = Service

---@param name string
---@param conf table
---@return table
function Service.new(name, conf)
    return setmetatable({
        name = name,
        conf = conf or {},
        node = type(conf) == "table" and conf.node or nil,
    }, Service)
end

local function respond(sender, session, ok, ...)
    if session == 0 then
        return
    end
    if ok then
        moon.response("lua", sender, session, ...)
    else
        moon.response("lua", sender, session, false, ...)
    end
end

--- Install dispatch + lifecycle for the calling service.
---
--- `spec` fields:
---   * `name`      string    service name (also the routing key)
---   * `commands`  table     command name -> `function(self, ...)`
---   * `on_init`   function  called after dispatch is installed  `(self)`
---   * `on_start`  function  called after init                   `(self)`
---   * `on_stop`   function  called on graceful shutdown         `(self)`
---@param spec table
---@param conf? table the params table forwarded by the service script (`...`)
---@return table service instance
function M.run(spec, conf)
    conf = conf or {}
    local name = spec.name or (type(conf) == "table" and conf.name) or moon.name
    local self = Service.new(name, conf)
    local commands = spec.commands or {}

    if type(conf) == "table" and conf.routing then
        router.configure({ node_id = conf.node, services = conf.routing })
    end

    moon.dispatch("lua", function(sender, session, cmd, ...)
        local handler = commands[cmd]
        if not handler then
            moon.error(string.format("[%s] unknown command: %s", tostring(name), tostring(cmd)))
            respond(sender, session, false, "unknown command: " .. tostring(cmd))
            return
        end
        local args = table.pack(...)
        local packed = table.pack(xpcall(function()
            return handler(self, table.unpack(args, 1, args.n))
        end, debug.traceback))
        if packed[1] then
            respond(sender, session, true, table.unpack(packed, 2, packed.n))
        else
            moon.error(string.format("[%s] command '%s' failed: %s", tostring(name), tostring(cmd), tostring(packed[2])))
            respond(sender, session, false, packed[2])
        end
    end)

    if spec.on_init then
        spec.on_init(self)
    end

    moon.shutdown(function()
        moon.async(function()
            if spec.on_stop then
                local ok, err = pcall(spec.on_stop, self)
                if not ok then
                    moon.error(string.format("[%s] on_stop failed: %s", tostring(name), tostring(err)))
                end
            end
            moon.quit()
        end)
    end)

    if spec.on_start then
        spec.on_start(self)
    end

    return self
end

return M

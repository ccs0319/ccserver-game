--- Health / readiness check registry.
---
--- Services (or the app) register named checks; the admin endpoint runs them to
--- answer readiness probes. A check returns `ok, err`; anything other than
--- `true` (or a raised error) marks the component unhealthy.
---
--- ```lua
--- local health = require("ccserver.health")
--- health.register("db", function() return db.health("sql", "game") end)
--- local ok, results = health.run()
--- ```

local M = {}

---@type table<string, fun():boolean, any>
local checks = {}

---@param name string
---@param fn fun():boolean, any
function M.register(name, fn)
    checks[name] = fn
end

---@param name string
function M.unregister(name)
    checks[name] = nil
end

--- Run all checks.
---@return boolean all_ok
---@return table results `{ { name, ok, err }, ... }` (sorted by name)
function M.run()
    local results = {}
    local all_ok = true
    for name, fn in pairs(checks) do
        local called, res, err = pcall(fn)
        local ok
        if not called then
            ok, err = false, res
        else
            ok = (res == true)
            if ok then
                err = nil
            end
        end
        if not ok then
            all_ok = false
        end
        results[#results + 1] = { name = name, ok = ok, err = err }
    end
    table.sort(results, function(a, b) return a.name < b.name end)
    return all_ok, results
end

return M

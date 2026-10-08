--- Code hot reload built on the runtime's `hotfix` (function-level patching).
---
--- A module must be loaded through `hotreload.require` (instead of the plain
--- `require`) so a later `hotreload.update` can patch its functions in place,
--- preserving upvalues and live references held by other code.
---
--- `hotreload.watch` polls the module files and hot-updates on change. Each
--- actor owns its own Lua state, so a watcher only reloads the current actor;
--- run one watcher per service (or broadcast a reload command to all services).
---
--- ```lua
--- local hotreload = require("moon.hotreload")
--- local logic = hotreload.require("game.logic")
--- hotreload.watch("game.logic", 2000, function(name, ok, err)
---     if not ok then moon.error(err) end
--- end)
--- ```

local moon = require("moon")
local hotfix = require("hotfix")

local M = {}

local searcher_registered = false

-- Register a filesystem searcher so `hotfix.require`/`hotfix.update` can locate
-- modules through `package.path`. `hotfix.findloader` expects the searcher to
-- return the *compiled chunk* itself (plus an extra arg), so that `hotfix.diff`
-- can walk the module's whole prototype tree (including the functions it
-- returns); wrapping the chunk in a closure would hide those protos.
local function ensure_searcher()
    if searcher_registered then
        return
    end
    hotfix.addsearcher(function(name)
        local path = package.searchpath(name, package.path)
        if not path then
            return string.format("\n\tno module '%s' in package.path", name)
        end
        local chunk = assert(load(io.readfile(path), "@" .. path))
        return chunk, path
    end)
    searcher_registered = true
end

--- Require a module through hotfix so it can later be updated in place.
---@param name string
---@return any
function M.require(name)
    ensure_searcher()
    return hotfix.require(name)
end

--- Hot-update a module previously loaded with `M.require`.
---@param name string
---@param updatename? string
---@return boolean ok
---@return any err
function M.update(name, updatename)
    ensure_searcher()
    return hotfix.update(name, updatename)
end

--- Poll the files of the given modules and hot-update them on change.
---@param names string|string[]
---@param interval_ms integer
---@param on_reload? fun(name:string, ok:boolean, err:any)
---@return table handle with `:stop()`
function M.watch(names, interval_ms, on_reload)
    if type(names) == "string" then
        names = { names }
    end
    interval_ms = interval_ms or 2000
    local handle = { stopped = false }
    local snapshots = {}
    for _, name in ipairs(names) do
        local path = package.searchpath(name, package.path)
        if path then
            snapshots[name] = { path = path, content = io.readfile(path) }
        end
    end

    local function tick()
        if handle.stopped then
            return
        end
        for name, snap in pairs(snapshots) do
            local content = io.readfile(snap.path)
            if content ~= snap.content then
                snap.content = content
                local ok, result = M.update(name)
                if on_reload then
                    on_reload(name, ok, result)
                end
                if ok then
                    moon.info("hot reloaded module: " .. name)
                else
                    moon.error(string.format("hot reload failed: %s: %s", name, tostring(result)))
                end
            end
        end
        moon.timeout(interval_ms, tick)
    end

    moon.timeout(interval_ms, tick)
    function handle:stop()
        self.stopped = true
    end
    return handle
end

return M

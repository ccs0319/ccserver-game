--- Configuration loading with hot reload.
---
--- Supports `.lua` (a file returning a table) and `.json` config files.
--- `watch` polls a file and calls `on_change(new, old, path)` whenever its
--- content changes, which is the usual way to hot-update game config tables.
---
--- ```lua
--- local config = require("moon.config")
--- local cfg = config.load("config/server.lua")
--- config.watch("config/server.lua", 2000, function(new, old)
---     apply_config(new, old)
--- end)
--- ```

local moon = require("moon")
local json = require("json")

local M = {}

local function read(path)
    local ext = path:match("%.([%a%d]+)$")
    if ext == "json" then
        return json.decode(io.readfile(path))
    elseif ext == "lua" then
        local chunk = assert(load(io.readfile(path), "@" .. path), "config: cannot load " .. path)
        return chunk()
    end
    error("config: unsupported file type: " .. path)
end

--- Load a config file once.
---@param path string
---@return table
function M.load(path)
    return read(path)
end

--- Poll `path` every `interval_ms`; on content change, reload and invoke
--- `on_change(new, old, path)`. Reload errors are logged and keep the old value.
---@param path string
---@param interval_ms integer
---@param on_change? fun(new:table, old:table, path:string)
---@return table handle with `:stop()` and `:get()`
function M.watch(path, interval_ms, on_change)
    interval_ms = interval_ms or 2000
    local handle = { stopped = false, path = path }
    local last_content = io.readfile(path)
    local current = read(path)

    local function tick()
        if handle.stopped then
            return
        end
        local content = io.readfile(path)
        if content ~= last_content then
            last_content = content
            local ok, result = pcall(read, path)
            if ok then
                local old = current
                current = result
                if on_change then
                    on_change(result, old, path)
                end
                moon.info("config reloaded: " .. path)
            else
                moon.error("config reload failed: " .. tostring(result))
            end
        end
        moon.timeout(interval_ms, tick)
    end

    moon.timeout(interval_ms, tick)
    function handle:stop()
        self.stopped = true
    end
    function handle:get()
        return current
    end
    return handle
end

return M

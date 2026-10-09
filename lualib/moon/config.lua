--- Configuration loading with layering, schema validation and hot reload.
---
--- Supports `.lua` (a file returning a table) and `.json` config files.
---
--- ```lua
--- local config = require("moon.config")
---
--- -- layered: base <- env overrides
--- local cfg = config.load_layered({ "config/base.lua", "config/dev.lua" })
---
--- -- schema validation (raises with the offending path)
--- config.validate(cfg, {
---     port = "integer",
---     db = { redis = "table", sql = "table" },
--- })
---
--- -- hot reload, rejecting invalid updates (keeps the previous value)
--- config.watch("config/server.lua", 2000, apply, {
---     schema = { port = "integer" },
--- })
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

--- Deep-merge `override` into `base` (recursing into tables); returns `base`.
--- Scalars and non-table values from `override` win.
---@param base table
---@param override table
---@return table
function M.merge(base, override)
    base = base or {}
    for k, v in pairs(override or {}) do
        if type(v) == "table" and type(base[k]) == "table" then
            M.merge(base[k], v)
        else
            base[k] = v
        end
    end
    return base
end

local function type_matches(v, want)
    local t = type(v)
    if want == "integer" then
        return t == "number" and v % 1 == 0
    end
    return t == want
end

--- Validate `cfg` against a `schema`. Schema is a map of key -> expected type
--- (`"string"|"number"|"integer"|"boolean"|"table"`) or a nested schema table.
--- Raises with the offending dotted path on the first problem.
---@param cfg table
---@param schema table
---@param path? string
---@return boolean
function M.validate(cfg, schema, path)
    path = path or ""
    if type(cfg) ~= "table" then
        error(string.format("config: `%s` must be a table, got %s", path, type(cfg)))
    end
    for key, want in pairs(schema or {}) do
        local full = (path == "") and tostring(key) or (path .. "." .. tostring(key))
        local v = cfg[key]
        if v == nil then
            error(string.format("config: missing required field `%s`", full))
        elseif type(want) == "table" then
            M.validate(v, want, full)
        elseif not type_matches(v, want) then
            error(string.format("config: field `%s` expected %s, got %s", full, want, type(v)))
        end
    end
    return true
end

--- Load several config files and deep-merge them left-to-right (later wins).
---@param paths string[]
---@return table
function M.load_layered(paths)
    local merged = {}
    for _, p in ipairs(paths) do
        M.merge(merged, read(p))
    end
    return merged
end

--- Poll `path` every `interval_ms`; on content change, reload and invoke
--- `on_change(new, old, path)`. With `opts.schema`, invalid reloads are logged
--- and the previous value is kept.
---@param path string
---@param interval_ms integer
---@param on_change? fun(new:table, old:table, path:string)
---@param opts? table `{ schema = table }`
---@return table handle with `:stop()` and `:get()`
function M.watch(path, interval_ms, on_change, opts)
    interval_ms = interval_ms or 2000
    opts = opts or {}
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
            local ok, result = pcall(function()
                local cfg = read(path)
                if opts.schema then
                    M.validate(cfg, opts.schema)
                end
                return cfg
            end)
            if ok then
                local old = current
                current = result
                if on_change then
                    on_change(result, old, path)
                end
                moon.info("config reloaded: " .. path)
            else
                moon.error("config reload rejected: " .. tostring(result))
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

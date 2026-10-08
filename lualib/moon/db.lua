--- Unified database connection manager for ccserver.
---
--- Recommended stack:
---   * **Redis**  — cache / session / ranking (use sorted sets for leaderboards).
---   * **SQLx**   — relational databases via one API: MySQL / PostgreSQL / SQLite.
---   * **MongoDB** — optional document store (requires a build with `--features mongodb`).
---
--- Native drivers live in `lualib/moon/db/*.lua`; this module opens them together
--- from a single config table and hands back named handles.
---
--- ```lua
--- local db = require("moon.db")
---
--- db.setup {
---     redis = {
---         { name = "cache", url = "redis://127.0.0.1:6379/0?pool_size=2" },
---     },
---     sql = {
---         { name = "game", url = "mysql://user:pass@127.0.0.1:3306/game",
---           max_connections = 8, timeout = 5000 },
---         { name = "stat", url = "postgres://user:pass@127.0.0.1:5432/stat" },
---     },
---     -- mongo = { { name = "log", url = "mongodb://127.0.0.1:27017" } },
--- }
---
--- local cache = db.redis("cache")   -- moon.db.redis connection
--- local game  = db.sql("game")      -- moon.db.sqlx connection
--- ```
---
--- All connections are opened asynchronously (coroutine yield) and must be set up
--- from within an actor. Call `db.close_all()` on shutdown.

local moon = require("moon")

local M = {}

local handles = {
    redis = {},
    sql = {},
    mongo = {},
}

local function require_redis()
    if not M._redis then
        M._redis = require("moon.db.redis")
    end
    return M._redis
end

local function require_sqlx()
    if not M._sqlx then
        local ok, mod = pcall(require, "moon.db.sqlx")
        if not ok then
            error("moon.db: sqlx support is not compiled in (build with `--features sqlx`)")
        end
        M._sqlx = mod
    end
    return M._sqlx
end

local function require_mongodb()
    if not M._mongodb then
        local ok, mod = pcall(require, "moon.db.mongodb")
        if not ok then
            error("moon.db: mongodb support is not compiled in (build with `--features mongodb`)")
        end
        M._mongodb = mod
    end
    return M._mongodb
end

--- Append `name=<name>` to a redis URL if it does not already carry one, so the
--- native pool is registered under a predictable name.
local function ensure_redis_name(url, name)
    if url:find("[?&]name=") then
        return url
    end
    return url .. (url:find("?", 1, true) and "&" or "?") .. "name=" .. name
end

local function open_redis(cfg)
    local mod = require_redis()
    local url = ensure_redis_name(assert(cfg.url, "moon.db: redis url required"), cfg.name)
    local conn, err = mod.connect(url)
    if not conn then
        error(string.format("moon.db: redis `%s` connect failed: %s", cfg.name, tostring(err)))
    end
    handles.redis[cfg.name] = conn
    return conn
end

local function open_sql(cfg)
    local mod = require_sqlx()
    local conn = mod.connect(assert(cfg.url, "moon.db: sql url required"), cfg.name,
        cfg.timeout, cfg.max_connections, cfg.queue_capacity)
    handles.sql[cfg.name] = conn
    return conn
end

local function open_mongo(cfg)
    local mod = require_mongodb()
    local conn = mod.connect(assert(cfg.url, "moon.db: mongo url required"), cfg.name,
        cfg.queue_capacity)
    handles.mongo[cfg.name] = conn
    return conn
end

--- Open every connection declared in `config`. Idempotent per name (re-opens and
--- replaces on repeat calls).
---@param config table @ `{ redis = {...}, sql = {...}, mongo = {...} }`
---@return table self
function M.setup(config)
    config = config or {}
    local function each(kind, list, opener)
        for _, cfg in ipairs(list or {}) do
            cfg.name = cfg.name or "default"
            opener(cfg)
            moon.info(string.format("moon.db: %s `%s` connected", kind, cfg.name))
        end
    end
    each("redis", config.redis, open_redis)
    each("sql", config.sql, open_sql)
    each("mongo", config.mongo, open_mongo)
    return M
end

---@param name? string defaults to "default"
---@return moon.db.redis|nil
function M.redis(name)
    return handles.redis[name or "default"]
end

---@param name? string defaults to "default"
---@return moon.db.sqlx|nil
function M.sql(name)
    return handles.sql[name or "default"]
end

---@param name? string defaults to "default"
---@return table|nil mongodb connection
function M.mongo(name)
    return handles.mongo[name or "default"]
end

--- Close every managed connection and clear the registry.
function M.close_all()
    for _, c in pairs(handles.redis) do c:close() end
    for _, c in pairs(handles.sql) do c:close() end
    for _, c in pairs(handles.mongo) do c:close() end
    handles.redis, handles.sql, handles.mongo = {}, {}, {}
end

return M

---
--- example_server.lua — minimal "one-click" server bootstrap.
---
--- Wires together the infrastructure pieces:
---   config (env overrides) -> DB connections -> schema migrations ->
---   background timer -> graceful shutdown.
---
--- Run:  moon_rs assets/example/example_server.lua
--- Env:  CCS_REDIS_URL, CCS_MYSQL_URL, CCS_PG_URL, CCS_MIGRATIONS_DIR

local moon = require("moon")
local db = require("moon.db")
local migration = require("moon.db.migration")

moon.loglevel("INFO")

local function env(name, default)
    return os.getenv(name) or default
end

local config = {
    redis_url = env("CCS_REDIS_URL", "redis://127.0.0.1:6379/0"),
    sql_url = env("CCS_MYSQL_URL", "mysql://root:123456@127.0.0.1:3306/game"),
    migrations_dir = env("CCS_MIGRATIONS_DIR", "../migration"),
}

moon.async(function()
    print("booting ccserver...")

    -- Relational database is required.
    local ok, err = pcall(db.setup, {
        sql = { { name = "game", url = config.sql_url, max_connections = 8 } },
    })
    if not ok then
        moon.error("sql setup failed: " .. tostring(err))
        moon.exit(1)
        return
    end

    local applied = migration.run(db.sql("game"), config.migrations_dir)
    print(string.format("migrations applied: %d", #applied))

    -- Cache is optional: the server keeps running without it.
    local rok, rerr = pcall(db.setup, {
        redis = { { name = "cache", url = config.redis_url } },
    })
    if not rok then
        moon.warning("redis unavailable, continuing without cache: " .. tostring(rerr))
    end

    print("server ready")

    -- Heartbeat demonstrating the actor timer + live DB access.
    moon.timeout(5000, function()
        local cache = db.redis("cache")
        if cache then
            cache:set("server:heartbeat", tostring(os.time()))
        end
        moon.info("heartbeat")
    end)
end)

moon.shutdown(function()
    print("shutting down...")
    db.close_all()
    moon.quit()
end)

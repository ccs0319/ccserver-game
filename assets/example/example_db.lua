---
--- example_db.lua — unified database manager (`moon.db`).
---
--- Run:  moon_rs assets/example/example_db.lua
---
--- Recommended stack: Redis (cache/session/rank) + SQLx (MySQL/PostgreSQL/SQLite).
--- SQLite runs in-memory so the relational part needs no external server; Redis
--- is exercised only when a local server is reachable.

local moon = require("moon")
local db = require("moon.db")

moon.loglevel("INFO")

moon.async(function()
    -----------------------------------------------------------------------
    -- 1. Relational: SQLite in-memory (self-contained).
    -----------------------------------------------------------------------
    db.setup {
        sql = {
            { name = "demo", url = "sqlite::memory:" },
        },
    }

    local sql = db.sql("demo")
    sql:query("CREATE TABLE player (uid INTEGER PRIMARY KEY, name TEXT, level INTEGER)")

    sql:query("INSERT INTO player (uid, name, level) VALUES (?, ?, ?)", 1, "Alice", 10)
    sql:query("INSERT INTO player (uid, name, level) VALUES (?, ?, ?)", 2, "Bob", 25)

    local rows = sql:query("SELECT uid, name, level FROM player ORDER BY uid")
    for _, row in ipairs(rows) do
        print(string.format("player uid=%s name=%s level=%s", row.uid, row.name, row.level))
    end

    local upd = sql:query("UPDATE player SET level = ? WHERE uid = ?", 11, 1)
    if upd.kind then
        print("update error:", upd.message)
    end

    -----------------------------------------------------------------------
    -- 2. Cache / ranking: Redis (skipped if no local server).
    -----------------------------------------------------------------------
    local ok, err = pcall(db.setup, {
        redis = {
            { name = "cache", url = "redis://127.0.0.1:6379/0?pool_size=1" },
        },
    })

    if not ok then
        print("redis skipped:", err)
    else
        local cache = db.redis("cache")
        cache:set("player:1:name", "Alice")
        print("cache player:1:name =", cache:get("player:1:name"))

        cache:zadd("rank", 100, "Alice")
        cache:zadd("rank", 250, "Bob")
        cache:zadd("rank", 180, "Carol")
        local top = cache:zrevrange("rank", 0, 2, "WITHSCORES")
        print("rank top:", table.concat(top, ", "))

        cache:del("player:1:name", "rank")
    end

    db.close_all()
    print("example_db done")
    moon.exit(0)
end)

moon.shutdown(function()
    moon.quit()
end)

---
--- test_db_stack.lua — integration test for the unified `moon.db` layer.
---
--- Requires: Redis (6379), MySQL, PostgreSQL. SQLite runs in-memory.
--- Run:  moon_rs assets/test/test_db_stack.lua
---
--- Exits non-zero if any check fails.

local moon = require("moon")
local db = require("moon.db")

moon.loglevel("INFO")

local failed = 0

local function check(cond, msg)
    if cond then
        print("  PASS " .. msg)
    else
        failed = failed + 1
        print("  FAIL " .. msg)
    end
end

local function setup_one(kind, cfg)
    local ok, err = pcall(db.setup, { [kind] = { cfg } })
    check(ok, string.format("connect %s `%s`", kind, cfg.name))
    if not ok then
        print("       " .. tostring(err))
    end
    return ok
end

---@param name string
---@param conn sqlx
---@param postgres boolean true = PostgreSQL `$1` placeholders, false = `?`
local function sql_roundtrip(name, conn, postgres)
    local function ph(i)
        return postgres and ("$" .. i) or "?"
    end
    print("[sql:" .. name .. "]")
    conn:query("DROP TABLE IF EXISTS player")
    local create = conn:query("CREATE TABLE player (uid INTEGER PRIMARY KEY, name VARCHAR(64), level INTEGER)")
    check(not create.kind, name .. " create table")

    local ins = conn:query(
        string.format("INSERT INTO player (uid, name, level) VALUES (%s, %s, %s)", ph(1), ph(2), ph(3)),
        1, "Alice", 10)
    check(not ins.kind, name .. " insert")

    local sel = conn:query(
        string.format("SELECT uid, name, level FROM player WHERE uid = %s", ph(1)), 1)
    check(type(sel) == "table" and not sel.kind and sel[1] and tostring(sel[1].name) == "Alice",
        name .. " select")

    local upd = conn:query(
        string.format("UPDATE player SET level = %s WHERE uid = %s", ph(1), ph(2)), 11, 1)
    check(not upd.kind, name .. " update")

    local after = conn:query(
        string.format("SELECT level FROM player WHERE uid = %s", ph(1)), 1)
    check(type(after) == "table" and after[1] and tonumber(after[1].level) == 11,
        name .. " update persisted")
end

local function redis_roundtrip()
    print("[redis]")
    local cache = db.redis("cache")
    if not cache then
        check(false, "redis handle")
        return
    end
    cache:flushdb()
    cache:set("player:1:name", "Alice")
    check(cache:get("player:1:name") == "Alice", "redis set/get")

    cache:zadd("rank", 100, "Alice")
    cache:zadd("rank", 250, "Bob")
    local top = cache:zrevrange("rank", 0, 0)
    check(type(top) == "table" and top[1] == "Bob", "redis zset ranking")
end

moon.async(function()
    print("=== moon.db integration test ===")

    local function env(name, default)
        return os.getenv(name) or default
    end
    local REDIS_URL = env("CCS_REDIS_URL", "redis://127.0.0.1:6379/0")
    local MYSQL_URL = env("CCS_MYSQL_URL", "mysql://root:123456@127.0.0.1:3306/game")
    local PG_URL = env("CCS_PG_URL", "postgres://ccs:123456@127.0.0.1:5432/game")

    if setup_one("redis", { name = "cache", url = REDIS_URL }) then
        redis_roundtrip()
    end

    if setup_one("sql", { name = "sqlite", url = "sqlite::memory:", max_connections = 1 }) then
        sql_roundtrip("sqlite", db.sql("sqlite"), false)
    end

    if setup_one("sql", { name = "mysql", url = MYSQL_URL }) then
        sql_roundtrip("mysql", db.sql("mysql"), false)
    end

    if setup_one("sql", { name = "pg", url = PG_URL }) then
        sql_roundtrip("pg", db.sql("pg"), true)
    end

    db.close_all()

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    moon.quit()
end)

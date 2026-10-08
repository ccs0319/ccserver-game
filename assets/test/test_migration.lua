---
--- test_migration.lua — schema migration runner integration test.
---
--- Requires: MySQL (3307), PostgreSQL (5433). SQLite runs in-memory.
--- Run:  moon_rs assets/test/test_migration.lua

local moon = require("moon")
local db = require("moon.db")
local migration = require("moon.db.migration")

moon.loglevel("INFO")

local MIG_DIR = "../migration"

local failed = 0
local function check(cond, msg)
    if cond then
        print("  PASS " .. msg)
    else
        failed = failed + 1
        print("  FAIL " .. msg)
    end
end

local function test_backend(name, url, max_conn)
    local ok, err = pcall(db.setup, { sql = { { name = name, url = url, max_connections = max_conn } } })
    check(ok, name .. " connect")
    if not ok then
        print("       " .. tostring(err))
        return
    end
    local conn = db.sql(name)
    conn:query("DROP TABLE IF EXISTS player")
    conn:query("DROP TABLE IF EXISTS schema_migrations")

    local first = migration.run(conn, MIG_DIR)
    check(#first == 2, name .. " applied 2 migrations (got " .. #first .. ")")

    local second = migration.run(conn, MIG_DIR)
    check(#second == 0, name .. " idempotent re-run (got " .. #second .. ")")

    local st = migration.status(conn)
    check(type(st) == "table" and #st == 2, name .. " status rows = 2")

    local ins = conn:query("INSERT INTO player (uid, name, level, created_at) VALUES (?, ?, ?, ?)",
        1, "Alice", 5, "2026-01-01")
    if name == "pg" then
        ins = conn:query("INSERT INTO player (uid, name, level, created_at) VALUES ($1, $2, $3, $4)",
            1, "Alice", 5, "2026-01-01")
    end
    check(not ins.kind, name .. " migrated schema is usable")
end

moon.async(function()
    print("=== migration integration test ===")
    local function env(name, default)
        return os.getenv(name) or default
    end
    test_backend("sqlite", "sqlite::memory:", 1)
    test_backend("mysql", env("CCS_MYSQL_URL", "mysql://root:123456@127.0.0.1:3306/game"))
    test_backend("pg", env("CCS_PG_URL", "postgres://ccs:123456@127.0.0.1:5432/game"))

    db.close_all()
    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    moon.quit()
end)

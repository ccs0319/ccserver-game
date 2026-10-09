---
--- test_migration.lua — schema migration runner integration test.
---
--- Requires: MySQL (3306/CCS_MYSQL_URL), PostgreSQL (5432/CCS_PG_URL). SQLite is
--- in-memory. Covers apply, idempotency, checksum verify, tamper detection and
--- rollback.
--- Run:  moon_rs assets/test/test_migration.lua

local moon = require("moon")
local fs = require("fs")
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

local function env(name, default)
    return os.getenv(name) or default
end

local function test_backend(name, url, backend, max_conn)
    local ok, err = pcall(db.setup, { sql = { { name = name, url = url, max_connections = max_conn } } })
    check(ok, name .. " connect")
    if not ok then
        print("       " .. tostring(err))
        return
    end
    local conn = db.sql(name)
    conn:query("DROP TABLE IF EXISTS player")
    conn:query("DROP TABLE IF EXISTS schema_migrations")

    local first = migration.run(conn, MIG_DIR, { backend = backend })
    check(#first == 2, name .. " applied 2 migrations (got " .. #first .. ")")

    local second = migration.run(conn, MIG_DIR, { backend = backend })
    check(#second == 0, name .. " idempotent re-run (got " .. #second .. ")")

    local st = migration.status(conn)
    check(type(st) == "table" and #st == 2 and st[1].checksum ~= nil, name .. " status has checksums")

    check(#migration.verify(conn, MIG_DIR) == 0, name .. " verify clean")

    local rolled = migration.rollback(conn, MIG_DIR, 1, { backend = backend })
    check(#rolled == 1, name .. " rolled back 1 (got " .. #rolled .. ")")
    check(#migration.status(conn) == 1, name .. " status = 1 after rollback")

    local ph = backend == "postgres" and "$1" or "?"
    local ins = conn:query(string.format(
        "INSERT INTO player (uid, name, level) VALUES (%s, %s, %s)", ph, ph, ph), 1, "Alice", 5)
    check(not ins.kind, name .. " schema usable after rollback")
end

moon.async(function()
    print("=== migration integration test ===")
    test_backend("sqlite", "sqlite::memory:", "sqlite", 1)
    test_backend("mysql", env("CCS_MYSQL_URL", "mysql://root:123456@127.0.0.1:3306/game"), "mysql")
    test_backend("pg", env("CCS_PG_URL", "postgres://ccs:123456@127.0.0.1:5432/game"), "postgres")

    -- Checksum tamper detection on a scratch migration directory.
    local dir = "/tmp/ccs_mig_test"
    fs.mkdir(dir)
    local p = dir .. "/0001_x.lua"
    db.setup { sql = { { name = "scratch", url = "sqlite::memory:", max_connections = 1 } } }
    local scratch = db.sql("scratch")
    scratch:query("DROP TABLE IF EXISTS t1")
    scratch:query("DROP TABLE IF EXISTS schema_migrations")

    io.writefile(p, "return { up = { [[CREATE TABLE t1 (id INTEGER)]] } }\n")
    migration.run(scratch, dir, { backend = "sqlite" })
    check(#migration.verify(scratch, dir) == 0, "checksum clean")

    io.writefile(p, "return { up = { [[CREATE TABLE t1 (id INTEGER, v INTEGER)]] } }\n")
    check(#migration.verify(scratch, dir) == 1, "checksum tamper detected")

    db.close_all()
    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    moon.quit()
end)

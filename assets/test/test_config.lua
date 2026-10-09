---
--- test_config.lua — layered config, schema validation and validated hot reload.
--- Run:  moon_rs assets/test/test_config.lua

local moon = require("moon")
local fs = require("fs")
local config = require("moon.config")

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

local dir = "/tmp/ccs_config_test"
fs.mkdir(dir)

moon.async(function()
    print("=== config test ===")

    -- Deep merge ---------------------------------------------------------
    local merged = config.merge({ a = { x = 1, y = 2 }, b = 1 }, { a = { y = 3, z = 4 }, c = 5 })
    check(merged.a.x == 1 and merged.a.y == 3 and merged.a.z == 4 and merged.b == 1 and merged.c == 5,
        "deep merge")

    -- Schema validation --------------------------------------------------
    local ok = pcall(config.validate, { port = 8080, db = { redis = {} } },
        { port = "integer", db = { redis = "table" } })
    check(ok, "validate accepts valid config")

    local ok2, err2 = pcall(config.validate, { port = 8080 }, { host = "string" })
    check(ok2 == false and tostring(err2):find("missing required field `host`") ~= nil,
        "validate rejects missing field")

    local ok3, err3 = pcall(config.validate, { port = "x" }, { port = "integer" })
    check(ok3 == false and tostring(err3):find("expected integer") ~= nil,
        "validate rejects wrong type")

    -- Layered load -------------------------------------------------------
    local base = dir .. "/base.lua"
    local dev = dir .. "/dev.lua"
    io.writefile(base, "return { port = 9000, db = { host = 'localhost' } }\n")
    io.writefile(dev, "return { port = 9001, db = { name = 'game' } }\n")
    local layered = config.load_layered({ base, dev })
    check(layered.port == 9001 and layered.db.host == "localhost" and layered.db.name == "game",
        "layered merge (later wins, tables merge)")

    -- Validated hot reload ----------------------------------------------
    local path = dir .. "/server.lua"
    io.writefile(path, "return { port = 1000 }\n")
    local changes = 0
    local handle = config.watch(path, 100, function() changes = changes + 1 end, {
        schema = { port = "integer" },
    })

    io.writefile(path, "return { port = 'bad' }\n")
    moon.sleep(300)
    check(changes == 0 and handle:get().port == 1000, "invalid reload rejected (kept old)")

    io.writefile(path, "return { port = 2000 }\n")
    moon.sleep(300)
    check(changes == 1 and handle:get().port == 2000, "valid reload applied")
    handle:stop()

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    moon.quit()
end)

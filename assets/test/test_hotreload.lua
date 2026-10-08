---
--- test_hotreload.lua — config + code hot reload test.
--- Run:  moon_rs assets/test/test_hotreload.lua

local moon = require("moon")
local fs = require("fs")
local config = require("moon.config")
local hotreload = require("moon.hotreload")

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

local dir = "/tmp/ccs_hotreload_test"
fs.mkdir(dir)
local mod_path = dir .. "/hotmod.lua"
local cfg_path = dir .. "/server.json"
package.path = dir .. "/?.lua;" .. package.path

local function write_mod(v)
    io.writefile(mod_path, string.format("return { value = function() return %q end }\n", v))
end

moon.async(function()
    print("=== hot reload test ===")

    -- Code hot reload -----------------------------------------------------
    write_mod("v1")
    local mod = hotreload.require("hotmod")
    check(mod.value() == "v1", "hotreload initial require")

    write_mod("v2")
    local ok, err = hotreload.update("hotmod")
    check(ok, "hotreload update ok (" .. tostring(err) .. ")")
    check(mod.value() == "v2", "hotreload value updated (got " .. tostring(mod.value()) .. ")")

    -- Config hot reload ---------------------------------------------------
    io.writefile(cfg_path, '{"port": 1000}')
    check(config.load(cfg_path).port == 1000, "config.load")

    local reloaded = nil
    local handle = config.watch(cfg_path, 100, function(new)
        reloaded = new
    end)
    io.writefile(cfg_path, '{"port": 2000}')
    moon.sleep(400)
    check(reloaded ~= nil and reloaded.port == 2000,
        "config hot reload (got " .. tostring(reloaded and reloaded.port) .. ")")
    handle:stop()

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    moon.quit()
end)

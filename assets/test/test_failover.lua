---
--- test_failover.lua — service groups: round-robin + failover + breaker.
---
--- Boots two lobby instances (lobby_1, lobby_2) as a group and verifies requests
--- are load-balanced, then that killing one instance fails over to the other.
--- Run:  moon_rs assets/test/test_failover.lua

local moon = require("moon")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local router = require("ccserver.router")

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

local cfg = topology.validate({
    cluster = { enabled = true, listen = false, discovery_url = "http://127.0.0.1:2379/cluster?node={}" },
    services = {
        login   = { source = "ccserver.services.login", unique = true },
        lobby_1 = { source = "ccserver.services.lobby", unique = true },
        lobby_2 = { source = "ccserver.services.lobby", unique = true },
        world   = { source = "ccserver.services.world", unique = true, config = { zone = 1 } },
    },
    groups = { lobby = { "lobby_1", "lobby_2" } },
    nodes = { [1] = { services = { "login", "lobby_1", "lobby_2", "world" } } },
})

moon.timeout(15000, function()
    moon.error("failover test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== failover test ===")
    node.start(cfg, 1)

    -- Round-robin across instances (info returns the serving instance name).
    local seen = {}
    for _ = 1, 4 do
        local info = router.call("lobby", "info")
        if type(info) == "table" and info.name then
            seen[info.name] = (seen[info.name] or 0) + 1
        end
    end
    check(seen.lobby_1 ~= nil and seen.lobby_2 ~= nil, "group load-balances across lobby_1 and lobby_2")

    -- Failover: kill lobby_2 and keep serving via lobby_1.
    moon.kill(node.query("lobby_2"))
    moon.sleep(50)
    check(node.query("lobby_2") == 0, "lobby_2 killed")

    local info = router.call("lobby", "info")
    check(type(info) == "table" and info.name == "lobby_1", "failover to lobby_1 after lobby_2 down")

    local a1 = router.call("lobby", "enter", 42)
    check(type(a1) == "table" and a1.uid == 42, "enter still served during failover")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

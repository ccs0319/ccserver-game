---
--- test_topology.lua — service topology skeleton integration test.
---
--- Boots a single node hosting gateway/login/lobby/world in-process and
--- exercises the service graph through the router.
--- Run:  moon_rs assets/test/test_topology.lua

local moon = require("moon")
local node = require("ccserver.node")
local router = require("ccserver.router")
local topology = require("ccserver.topology")

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
    cluster = {
        enabled = true,
        listen = false,
        discovery_url = "http://127.0.0.1:2379/cluster?node={}",
    },
    services = {
        gateway = { source = "ccserver.services.gateway", unique = true },
        login   = { source = "ccserver.services.login",   unique = true },
        lobby   = { source = "ccserver.services.lobby",   unique = true },
        world   = { source = "ccserver.services.world",   unique = true },
    },
    nodes = {
        [1] = { services = { "gateway", "login", "lobby", "world" } },
    },
})

moon.timeout(15000, function()
    moon.error("topology test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== topology test ===")
    node.start(cfg, 1)

    local auth, err = router.call("gateway", "login", "alice", "pw")
    check(type(auth) == "table" and auth.uid and auth.token,
        "gateway->login issues token (" .. tostring(err) .. ")")

    local session = router.call("gateway", "enter", auth.token)
    check(type(session) == "table" and session.uid == auth.uid and session.lobby and session.world,
        "gateway->login->lobby->world graph")

    local moved = router.call("gateway", "move", auth.uid, 5, 7)
    check(moved == true, "gateway->world move")

    local ok, e = router.call("gateway", "does_not_exist")
    check(ok == false and type(e) == "string", "unknown command -> false,err (no hang)")

    local bad, berr = router.call("login", "verify", "garbage")
    check(bad == false and berr == "invalid token", "login.verify rejects bad token")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

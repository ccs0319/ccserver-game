---
--- test_topology.lua — service topology skeleton integration test.
---
--- Boots a single node hosting gateway/login/lobby/world in-process and
--- exercises the service graph directly through the router (no client socket).
--- The client wire protocol is covered by test_gateway.lua.
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
        gateway = { source = "ccserver.services.gateway", unique = true, config = { addr = "127.0.0.1:19102" } },
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

    -- Services are registered and addressable by name.
    for _, name in ipairs({ "gateway", "login", "lobby", "world" }) do
        check(node.query(name) ~= 0, "service '" .. name .. "' registered")
    end

    -- Routing map: every service maps to node 1.
    local nodes = topology.service_nodes(cfg)
    check(nodes.login == 1 and nodes.world == 1, "service_nodes map")

    -- Service graph via the router.
    local auth, err = router.call("login", "login", "bob", "pw")
    check(type(auth) == "table" and auth.uid and auth.token, "login issues token (" .. tostring(err) .. ")")

    local verified = router.call("login", "verify", auth.token)
    check(type(verified) == "table" and verified.uid == auth.uid, "login verifies token")

    local lobby = router.call("lobby", "enter", auth.uid)
    check(type(lobby) == "table" and lobby.uid == auth.uid, "lobby enter")

    local world = router.call("world", "enter", auth.uid, 1)
    check(type(world) == "table" and world.zone == 1, "world enter")

    local moved = router.call("world", "move", auth.uid, 5, 7)
    check(moved == true, "world move")

    local bad, berr = router.call("login", "verify", "garbage")
    check(bad == false and berr == "invalid token", "login.verify rejects bad token")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

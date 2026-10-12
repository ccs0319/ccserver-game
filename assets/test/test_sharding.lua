---
--- test_sharding.lua — world sharding by zone (single node).
---
--- Boots gateway + login + lobby + world_1(zone 1) + world_2(zone 2) and drives
--- the gateway as a client, verifying ENTER/MOVE route to the shard for the
--- player's zone.
--- Run:  moon_rs assets/test/test_sharding.lua

local moon = require("moon")
local socket = require("moon.socket")
local buffer = require("buffer")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local router = require("ccserver.router")
local protocol = require("ccserver.protocol")

local MSG = protocol.MSG
local TYPE = protocol.TYPE
local ADDR = "127.0.0.1:19131"

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

local seq = 0
local pending = {}
local function request(fd, msgid, ...)
    seq = seq + 1
    local myseq = seq
    pending[myseq] = coroutine.running()
    socket.write_frame(fd, protocol.encode(TYPE.REQUEST, msgid, myseq, ...))
    local r = table.pack(moon.wait())
    pending[myseq] = nil
    return table.unpack(r, 1, r.n)
end
socket.on("message", function(fd, buf)
    local msg = protocol.decode(buffer.unpack(buf, "Z"))
    if msg and msg.type == TYPE.RESPONSE then
        local co = pending[msg.seq]
        if co then
            moon.wakeup(co, table.unpack(msg.args, 1, msg.args.n))
        end
    end
end)

local cfg = topology.validate({
    cluster = { enabled = true, listen = false, discovery_url = "http://127.0.0.1:2379/cluster?node={}" },
    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = {
            addr = ADDR,
            worlds = { [1] = "world_1", [2] = "world_2" },
        } },
        login   = { source = "ccserver.services.login", unique = true },
        lobby   = { source = "ccserver.services.lobby", unique = true },
        world_1 = { source = "ccserver.services.world", unique = true, config = { zone = 1 } },
        world_2 = { source = "ccserver.services.world", unique = true, config = { zone = 2 } },
    },
    nodes = { [1] = { services = { "gateway", "login", "lobby", "world_1", "world_2" } } },
})

moon.timeout(15000, function()
    moon.error("sharding test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== world sharding test ===")
    node.start(cfg, 1)

    local fd = assert(socket.connect(ADDR, 5000))
    socket.start_read_frame(fd)

    request(fd, MSG.HELLO, protocol.VERSION)
    local _, login = request(fd, MSG.LOGIN, "zoe", "pw")

    -- Zone 1 -> world_1
    local ok1, s1 = request(fd, MSG.ENTER, login.token, 1)
    check(ok1 == true and s1.zone == 1 and s1.world.zone == 1, "ENTER zone 1 -> world_1")
    local m1 = request(fd, MSG.MOVE, 3, 4)
    check(m1 == true, "MOVE routed to world_1")
    local e1 = router.call("world_1", "get", login.uid)
    check(e1 and e1.x == 3 and e1.y == 4, "world_1 has the entity")

    -- Zone 2 -> world_2 (same account re-enters; world shard differs)
    local ok2, s2 = request(fd, MSG.ENTER, login.token, 2)
    check(ok2 == true and s2.zone == 2 and s2.world.zone == 2, "ENTER zone 2 -> world_2")
    local m2 = request(fd, MSG.MOVE, 8, 9)
    check(m2 == true, "MOVE routed to world_2")
    local e2 = router.call("world_2", "get", login.uid)
    check(e2 and e2.x == 8 and e2.y == 9, "world_2 has the entity")

    -- Unknown zone is rejected.
    local ok3, err3 = request(fd, MSG.ENTER, login.token, 99)
    check(ok3 == false and tostring(err3):find("no world for zone") ~= nil, "unknown zone rejected")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

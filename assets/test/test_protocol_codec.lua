---
--- test_protocol_codec.lua — switchable payload codec (seri default / json).
---
--- Runs the gateway with `protocol = { codec = "json" }` and drives it with JSON
--- payloads, proving the payload codec is pluggable end-to-end.
--- Run:  moon_rs assets/test/test_protocol_codec.lua

local moon = require("moon")
local socket = require("moon.socket")
local buffer = require("buffer")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local protocol = require("ccserver.protocol")

local MSG = protocol.MSG
local TYPE = protocol.TYPE
local ADDR = "127.0.0.1:19161"

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

-- Client side uses JSON too (its own protocol module state).
protocol.set_codec("json")

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
    protocol = { codec = "json" },
    cluster = { enabled = true, listen = false, discovery_url = "http://127.0.0.1:2379/cluster?node={}" },
    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = {
            addr = ADDR, worlds = { [1] = "world" },
        } },
        login = { source = "ccserver.services.login", unique = true },
        lobby = { source = "ccserver.services.lobby", unique = true },
        world = { source = "ccserver.services.world", unique = true, config = { zone = 1 } },
    },
    nodes = { [1] = { services = { "gateway", "login", "lobby", "world" } } },
})

moon.timeout(15000, function()
    moon.error("protocol codec test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== protocol codec test (json) ===")
    node.start(cfg, 1)

    local fd = assert(socket.connect(ADDR, 5000))
    socket.start_read_frame(fd)

    local ok, ver = request(fd, MSG.HELLO, protocol.VERSION)
    check(ok == true and ver == protocol.VERSION, "HELLO over json payload")

    local _, login = request(fd, MSG.LOGIN, "json_user", "pw")
    check(type(login) == "table" and login.token ~= nil, "LOGIN over json payload")

    local eok, session = request(fd, MSG.ENTER, login.token, 1)
    check(eok == true and session.uid == login.uid and type(session.world) == "table",
        "ENTER over json payload (nested table survives)")

    local mok = request(fd, MSG.MOVE, 3, 4)
    check(mok == true, "MOVE over json payload")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

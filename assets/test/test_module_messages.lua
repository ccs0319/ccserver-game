---
--- test_module_messages.lua — module client-message auto-forwarding.
---
--- A module declares its client messages in the topology; the gateway assigns
--- msgids deterministically and forwards them to the owning service command
--- (no per-message gateway handler). Verified here against the lobby module.
--- Run:  moon_rs assets/test/test_module_messages.lua

local moon = require("moon")
local socket = require("moon.socket")
local buffer = require("buffer")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local protocol = require("ccserver.protocol")

local MSG = protocol.MSG
local TYPE = protocol.TYPE
local ADDR = "127.0.0.1:19151"

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
            addr = ADDR, worlds = { [1] = "world" },
        } },
        login   = { source = "ccserver.services.login", unique = true },
        lobby   = { source = "ccserver.services.lobby", unique = true,
                    client = { get = "get", leave = "leave" } },
        world   = { source = "ccserver.services.world", unique = true, config = { zone = 1 } },
    },
    nodes = { [1] = { services = { "gateway", "login", "lobby", "world" } } },
})

-- Same deterministic map the gateway builds.
local map = protocol.build(cfg)
local GET = protocol.module_id(map, "lobby", "get")
local LEAVE = protocol.module_id(map, "lobby", "leave")

moon.timeout(15000, function()
    moon.error("module messages test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== module messages test ===")
    check(GET ~= nil and LEAVE ~= nil and GET ~= LEAVE, "module msgids assigned (get=" .. tostring(GET) .. ")")
    node.start(cfg, 1)

    local fd = assert(socket.connect(ADDR, 5000))
    socket.start_read_frame(fd)

    -- Module message before ENTER must be rejected.
    request(fd, MSG.HELLO, protocol.VERSION)
    local pre, perr = request(fd, GET)
    check(pre == false and perr == "not entered", "module message before ENTER rejected")

    local _, login = request(fd, MSG.LOGIN, "eve", "pw")
    request(fd, MSG.ENTER, login.token, 1)
    -- Auto-forwarded module message: lobby.get(uid) -> lobby service (group).
    local ok, session = request(fd, GET)
    check(ok == true and type(session) == "table" and session.uid == login.uid,
        "lobby.get auto-forwarded to lobby service (group)")

    local lok = request(fd, LEAVE)
    check(lok == true, "lobby.leave auto-forwarded")

    local ok2, gone = request(fd, GET)
    check(ok2 == true and gone == nil, "lobby.get after leave returns nil")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

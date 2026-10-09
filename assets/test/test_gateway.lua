---
--- test_gateway.lua — client wire protocol + session integration test.
---
--- Boots a node (gateway listening on a local port) and drives it as a real TCP
--- client: HELLO version negotiation, LOGIN, ENTER (session bind), MOVE, PING,
--- version mismatch rejection, and 顶号 (duplicate login kicks the old session).
--- Run:  moon_rs assets/test/test_gateway.lua

local moon = require("moon")
local socket = require("moon.socket")
local buffer = require("buffer")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local protocol = require("ccserver.protocol")

local MSG = protocol.MSG
local TYPE = protocol.TYPE
local ADDR = "127.0.0.1:19101"

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

-- Client state -------------------------------------------------------------
local seq = 0
local pending = {}
local notices = {}
local closed = {}

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
    if not msg then
        return
    end
    if msg.type == TYPE.RESPONSE then
        local co = pending[msg.seq]
        if co then
            moon.wakeup(co, table.unpack(msg.args, 1, msg.args.n))
        end
    elseif msg.type == TYPE.NOTIFY then
        notices[fd] = notices[fd] or {}
        table.insert(notices[fd], { msgid = msg.msgid, args = msg.args })
    end
end)

socket.on("close", function(fd)
    closed[fd] = true
end)

local cfg = topology.validate({
    cluster = {
        enabled = true,
        listen = false,
        discovery_url = "http://127.0.0.1:2379/cluster?node={}",
    },
    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = { addr = ADDR } },
        login   = { source = "ccserver.services.login",   unique = true },
        lobby   = { source = "ccserver.services.lobby",   unique = true },
        world   = { source = "ccserver.services.world",   unique = true },
    },
    nodes = { [1] = { services = { "gateway", "login", "lobby", "world" } } },
})

moon.timeout(20000, function()
    moon.error("gateway test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== gateway protocol test ===")
    node.start(cfg, 1)

    local a = assert(socket.connect(ADDR, 5000))
    socket.start_read_frame(a)

    local ok, ver = request(a, MSG.HELLO, protocol.VERSION)
    check(ok == true and ver == protocol.VERSION, "HELLO negotiates version")

    local lok, login = request(a, MSG.LOGIN, "alice", "pw")
    check(lok == true and login and login.token, "LOGIN issues token")

    local eok, session = request(a, MSG.ENTER, login.token)
    check(eok == true and session.uid == login.uid and session.world ~= nil, "ENTER binds session")

    local mok, moved = request(a, MSG.MOVE, 5, 7)
    check(mok == true and moved.x == 5 and moved.y == 7, "MOVE routed to world")

    local pok, pong = request(a, MSG.PING)
    check(pok == true and pong == "pong", "PING/PONG")

    -- Version mismatch is rejected and the connection is closed.
    local b = assert(socket.connect(ADDR, 5000))
    socket.start_read_frame(b)
    local vok = request(b, MSG.HELLO, 999)
    check(vok == false, "version mismatch rejected")
    moon.sleep(50)
    check(closed[b] == true, "mismatched client closed")

    -- 顶号: a second login of the same account kicks client A.
    local c = assert(socket.connect(ADDR, 5000))
    socket.start_read_frame(c)
    request(c, MSG.HELLO, protocol.VERSION)
    local _, login2 = request(c, MSG.LOGIN, "alice", "pw")
    local eok2, session2 = request(c, MSG.ENTER, login2.token)
    check(eok2 == true and session2.uid == login.uid, "second client binds same uid")
    moon.sleep(100)

    local kicked = false
    for _, n in ipairs(notices[a] or {}) do
        if n.msgid == MSG.KICK then
            kicked = true
        end
    end
    check(kicked, "old session received KICK (顶号)")
    check(closed[a] == true, "old session closed")

    local uok, uerr = request(c, 12345)
    check(uok == false and type(uerr) == "string", "unknown msgid -> error")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

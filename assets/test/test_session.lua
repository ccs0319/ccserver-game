---
--- test_session.lua — cross-gateway session ownership + 顶号.
---
--- Two gateways share a Redis session store; logging the same account in on a
--- second gateway must kick the first gateway's connection.
--- Requires Redis (CCS_REDIS_URL).
--- Run:  moon_rs assets/test/test_session.lua

local moon = require("moon")
local socket = require("moon.socket")
local buffer = require("buffer")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local protocol = require("ccserver.protocol")

local MSG = protocol.MSG
local TYPE = protocol.TYPE
local ADDR1 = "127.0.0.1:19141"
local ADDR2 = "127.0.0.1:19142"

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
        table.insert(notices[fd], msg.msgid)
    end
end)
socket.on("close", function(fd) closed[fd] = true end)

local cfg = topology.validate({
    cluster = { enabled = true, listen = false, discovery_url = "http://127.0.0.1:2379/cluster?node={}" },
    services = {
        gateway_1 = { source = "ccserver.services.gateway", unique = true, config = {
            addr = ADDR1, worlds = { [1] = "world" },
            session = { redis_url = os.getenv("CCS_REDIS_URL") or "redis://127.0.0.1:6379/0" },
        } },
        gateway_2 = { source = "ccserver.services.gateway", unique = true, config = {
            addr = ADDR2, worlds = { [1] = "world" },
            session = { redis_url = os.getenv("CCS_REDIS_URL") or "redis://127.0.0.1:6379/0" },
        } },
        login = { source = "ccserver.services.login", unique = true },
        lobby = { source = "ccserver.services.lobby", unique = true },
        world = { source = "ccserver.services.world", unique = true, config = { zone = 1 } },
    },
    nodes = { [1] = { services = { "gateway_1", "gateway_2", "login", "lobby", "world" } } },
})

moon.timeout(20000, function()
    moon.error("session test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== cross-gateway session test ===")
    node.start(cfg, 1)
    moon.sleep(300) -- let gateways upgrade to the Redis session store

    -- Client A on gateway_1.
    local a = assert(socket.connect(ADDR1, 5000))
    socket.start_read_frame(a)
    request(a, MSG.HELLO, protocol.VERSION)
    local _, login = request(a, MSG.LOGIN, "dave", "pw")
    local eok = request(a, MSG.ENTER, login.token, 1)
    check(eok == true, "A enters via gateway_1")

    -- Client B on gateway_2, same account -> should kick A cross-gateway.
    local b = assert(socket.connect(ADDR2, 5000))
    socket.start_read_frame(b)
    request(b, MSG.HELLO, protocol.VERSION)
    local _, login2 = request(b, MSG.LOGIN, "dave", "pw")
    local eok2, s2 = request(b, MSG.ENTER, login2.token, 1)
    check(eok2 == true and s2.uid == login.uid, "B enters via gateway_2 (same uid)")
    moon.sleep(150)

    local kicked = false
    for _, id in ipairs(notices[a] or {}) do
        if id == MSG.KICK then
            kicked = true
        end
    end
    check(kicked, "A (gateway_1) received KICK from gateway_2 (cross-gateway 顶号)")
    check(closed[a] == true, "A connection closed")

    -- B remains usable.
    local m = request(b, MSG.MOVE, 1, 2)
    check(m == true, "B still served after 顶号")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

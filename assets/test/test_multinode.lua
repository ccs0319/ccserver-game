---
--- test_multinode.lua — cross-node routing check against a running cluster.
---
--- Requires the cluster from scripts/run-cluster.sh (node 1 gateway + world_1,
--- node 2 world_2). Connects to the gateway and enters zone 2, which lives on
--- the OTHER node, verifying cluster routing end-to-end.
---
--- Run:  CCS_BENCH_ADDR=127.0.0.1:9001 moon_rs assets/test/test_multinode.lua

local moon = require("moon")
local socket = require("moon.socket")
local buffer = require("buffer")
local protocol = require("ccserver.protocol")

local MSG = protocol.MSG
local TYPE = protocol.TYPE
local ADDR = os.getenv("CCS_BENCH_ADDR") or "127.0.0.1:9001"

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

moon.timeout(15000, function()
    moon.error("multinode test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== multinode routing test (gateway " .. ADDR .. ") ===")
    local fd = socket.connect(ADDR, 5000)
    if not fd then
        moon.error("cannot connect to gateway; is the cluster up?")
        moon.exit(1)
    end
    socket.start_read_frame(fd)

    request(fd, MSG.HELLO, protocol.VERSION)
    local _, login = request(fd, MSG.LOGIN, "remote_user", "pw")

    -- Zone 1 lives on node 1 (local to the gateway).
    local ok1, s1 = request(fd, MSG.ENTER, login.token, 1)
    check(ok1 == true and s1.world and s1.world.zone == 1, "zone 1 (local world_1)")

    -- Zone 2 lives on node 2 (remote) -> exercises cluster RPC.
    local ok2, s2 = request(fd, MSG.ENTER, login.token, 2)
    check(ok2 == true and s2.world and s2.world.zone == 2, "zone 2 (remote world_2 via cluster)")

    local m = request(fd, MSG.MOVE, 11, 22)
    check(m == true, "MOVE on remote world_2")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    moon.quit()
end)

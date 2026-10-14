---
--- test_gateway_ws.lua — WebSocket gateway end-to-end.
---
--- Boots a node whose gateway also listens for WebSocket (the transport a WeChat
--- mini-game uses), then drives it over `moon.websocket`. Over WebSocket each
--- message body is one WS binary message (no length framing).
--- Run:  moon_rs assets/test/test_gateway_ws.lua

local moon = require("moon")
local ws = require("moon.websocket")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local protocol = require("ccserver.protocol")

local MSG = protocol.MSG
local TYPE = protocol.TYPE
local WS_ADDR = "127.0.0.1:19171"

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
        gateway = { source = "ccserver.services.gateway", unique = true, config = {
            addr = "127.0.0.1:19172", ws_addr = WS_ADDR, worlds = { [1] = "world" },
        } },
        login = { source = "ccserver.services.login", unique = true },
        lobby = { source = "ccserver.services.lobby", unique = true },
        world = { source = "ccserver.services.world", unique = true, config = { zone = 1 } },
    },
    nodes = { [1] = { services = { "gateway", "login", "lobby", "world" } } },
})

moon.timeout(15000, function()
    moon.error("ws gateway test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== websocket gateway test ===")
    node.start(cfg, 1)
    moon.sleep(100)

    local conn = ws.connect("ws://" .. WS_ADDR, 5000)
    check(conn ~= nil, "ws connect to gateway")

    local seq = 0
    local function req(msgid, ...)
        seq = seq + 1
        local myseq = seq
        conn:write(protocol.encode(TYPE.REQUEST, msgid, myseq, ...))
        while true do
            local data, kind = conn:read(5000)
            if not data or kind == "c" then
                return nil, "connection closed"
            end
            if kind == "b" or kind == "t" then
                local msg = protocol.decode(data)
                if msg and msg.type == TYPE.RESPONSE and msg.seq == myseq then
                    return table.unpack(msg.args, 1, msg.args.n)
                end
            end
        end
    end

    local ok, ver = req(MSG.HELLO, protocol.VERSION)
    check(ok == true and ver == protocol.VERSION, "HELLO over WebSocket")

    local _, login = req(MSG.LOGIN, "ws_user", "pw")
    check(type(login) == "table" and login.token ~= nil, "LOGIN over WebSocket")

    local eok, session = req(MSG.ENTER, login.token, 1)
    check(eok == true and session.uid == login.uid and type(session.world) == "table", "ENTER over WebSocket")

    local mok = req(MSG.MOVE, 5, 6)
    check(mok == true, "MOVE over WebSocket")

    conn:close()

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

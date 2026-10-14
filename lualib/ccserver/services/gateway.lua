--- gateway service — client-facing edge (TCP **and** WebSocket).
---
--- Terminates client connections (raw TCP or WebSocket — the latter is what a
--- WeChat mini-game uses), enforces the wire protocol, manages sessions, and
--- orchestrates the backend service graph. It holds **no** auth secrets.
---
--- The protocol handling is **transport-agnostic**: a session carries `write`
--- and `close` closures, so the same handlers serve TCP (fd + frame protocol) and
--- WebSocket (per-connection coroutine). Over WebSocket each message body is one
--- WS binary message (no length framing needed); over TCP the runtime's frame
--- protocol provides framing.
---
--- Config (`services.gateway.config`, or env):
---   addr     = "0.0.0.0:9001"   TCP listen (env CCS_GATEWAY_ADDR)
---   ws_addr  = "0.0.0.0:9011"   WebSocket listen (env CCS_GATEWAY_WS_ADDR; optional)

local moon = require("moon")
local socket = require("moon.socket")
local websocket = require("moon.websocket")
local buffer = require("buffer")
local service = require("ccserver.service")
local router = require("ccserver.router")
local protocol = require("ccserver.protocol")
local metrics = require("ccserver.metrics")
local trace = require("ccserver.trace")
local ratelimit = require("ccserver.ratelimit")
local session = require("ccserver.session")

local MSG = protocol.MSG
local TYPE = protocol.TYPE

---@type table<string, table> id -> session
local sessions = {}
---@type table<integer, string> uid -> session id
local by_uid = {}
local active_connections = 0

local gateway_name
local gateway_node
local session_store
local client_routes

local rate_per_sec = 20
local rate_burst = 40
local drain_grace_ms = 300
local draining = false
local worlds = { [1] = "world" }

metrics.counter("ccserver_connections_total", "Client connections accepted")
metrics.gauge("ccserver_connections_active", "Currently open client connections")
metrics.counter("ccserver_client_messages_total", "Client messages handled")
metrics.counter("ccserver_errors_total", "Errors returned to clients")
metrics.counter("ccserver_rate_limited_total", "Client messages dropped by rate limit")
metrics.histogram("ccserver_client_request_seconds", "Client request handling latency")

--------------------------------------------------------------------------------
-- Transport-agnostic send
--------------------------------------------------------------------------------

local function send(s, mtype, msgid, seq, ...)
    if not sessions[s.id] then
        return
    end
    s.write(protocol.encode(mtype, msgid, seq, ...))
end

local function reply(s, msgid, seq, ok, ...)
    send(s, TYPE.RESPONSE, msgid, seq, ok, ...)
end

local function notify(s, msgid, ...)
    send(s, TYPE.NOTIFY, msgid, 0, ...)
end

local function close_session(s)
    if not sessions[s.id] then
        return
    end
    sessions[s.id] = nil
    if s.uid and by_uid[s.uid] == s.id then
        by_uid[s.uid] = nil
        if session_store then
            session_store.del(s.uid, gateway_name)
        end
    end
    s.close()
    active_connections = active_connections - 1
    metrics.set("ccserver_connections_active", active_connections)
    ratelimit.reset(s.id)
end

--------------------------------------------------------------------------------
-- Client command handlers: handler(session, seq, ...args)
--------------------------------------------------------------------------------

local handlers = {}

function handlers.HELLO(s, seq, client_version)
    if client_version ~= protocol.VERSION then
        reply(s, MSG.HELLO_ACK, seq, false,
            string.format("unsupported protocol version %s (server=%d)", tostring(client_version), protocol.VERSION))
        close_session(s)
        return
    end
    s.ver = client_version
    reply(s, MSG.HELLO_ACK, seq, true, protocol.VERSION)
end

function handlers.LOGIN(s, seq, account, password)
    if not s.ver then
        reply(s, MSG.LOGIN, seq, false, "hello required")
        return
    end
    local auth, err = router.call("login", "login", account, password)
    if not auth then
        reply(s, MSG.LOGIN, seq, false, err or "login failed")
        return
    end
    s.token = auth.token
    reply(s, MSG.LOGIN, seq, true, { uid = auth.uid, token = auth.token })
end

function handlers.ENTER(s, seq, token, zone)
    if not s.ver then
        reply(s, MSG.ENTER, seq, false, "hello required")
        return
    end
    local auth, err = router.call("login", "verify", token)
    if not auth then
        reply(s, MSG.ENTER, seq, false, err or "auth failed")
        return
    end

    zone = tonumber(zone) or zone or 1
    local world_name = worlds[zone]
    if not world_name then
        reply(s, MSG.ENTER, seq, false, "no world for zone " .. tostring(zone))
        return
    end

    -- Cross-gateway 顶号: if another gateway owns this uid, ask it to kick.
    if session_store then
        local prev = session_store.get(auth.uid)
        if prev and prev.gateway and prev.gateway ~= gateway_name then
            pcall(function() router.call(prev.gateway, "kick", auth.uid) end)
        end
        session_store.set(auth.uid, { gateway = gateway_name, node = gateway_node, zone = zone, ts = os.time() })
    end

    -- 顶号: kick any existing local session bound to this uid.
    local old_id = by_uid[auth.uid]
    if old_id and old_id ~= s.id then
        local old = sessions[old_id]
        if old then
            notify(old, MSG.KICK, "account logged in elsewhere")
            close_session(old)
        end
    end

    s.uid = auth.uid
    s.token = token
    s.zone = zone
    s.world = world_name
    by_uid[auth.uid] = s.id

    local lobby = router.call("lobby", "enter", auth.uid)
    local world = router.call(world_name, "enter", auth.uid, zone)
    reply(s, MSG.ENTER, seq, true,
        { uid = auth.uid, account = auth.account, zone = zone, lobby = lobby, world = world })
end

function handlers.MOVE(s, seq, x, y)
    if not s.uid then
        reply(s, MSG.MOVE, seq, false, "not entered")
        return
    end
    local ok, err = router.call(s.world or "world", "move", s.uid, x, y)
    reply(s, MSG.MOVE, seq, ok, ok and { x = x, y = y } or err)
end

function handlers.PING(s, seq)
    reply(s, MSG.PING, seq, true, "pong")
end

--------------------------------------------------------------------------------
-- Dispatch (transport-agnostic)
--------------------------------------------------------------------------------

local function handle_body(s, body)
    local msg, err = protocol.decode(body)
    if not msg then
        notify(s, MSG.ERROR, err)
        close_session(s)
        return
    end
    if msg.type ~= TYPE.REQUEST then
        return
    end

    if not ratelimit.allow(s.id, rate_per_sec, rate_burst) then
        metrics.inc("ccserver_rate_limited_total")
        reply(s, MSG.ERROR, msg.seq, false, "rate limited")
        return
    end

    local name = protocol.msg_name(msg.msgid)
    local handler = name and handlers[name]
    local route = (not handler) and client_routes and client_routes[msg.msgid] or nil
    if not handler and not route then
        metrics.inc("ccserver_errors_total")
        reply(s, MSG.ERROR, msg.seq, false, "unknown msgid: " .. tostring(msg.msgid))
        return
    end
    local label = handler and name or route.name
    metrics.inc("ccserver_client_messages_total", 1, { msgid = label })

    local args = msg.args
    local mseq = msg.seq
    local msgid = msg.msgid
    moon.async(function()
        local tid = trace.start()
        local started = moon.clock()
        local packed
        if handler then
            packed = table.pack(xpcall(function()
                return handler(s, mseq, table.unpack(args, 1, args.n))
            end, debug.traceback))
        elseif not s.uid then
            reply(s, MSG.ERROR, mseq, false, "not entered")
        else
            packed = table.pack(xpcall(function()
                local r = table.pack(router.call(route.service, route.cmd, s.uid, table.unpack(args, 1, args.n)))
                if r[1] == false then
                    reply(s, msgid, mseq, false, r[2])
                else
                    reply(s, msgid, mseq, true, table.unpack(r, 1, r.n))
                end
            end, debug.traceback))
        end
        metrics.observe("ccserver_client_request_seconds", moon.clock() - started, { msgid = label })
        if packed and not packed[1] then
            metrics.inc("ccserver_errors_total")
            moon.error(string.format("[trace %s] gateway handler error: %s", tid, tostring(packed[2])))
            reply(s, MSG.ERROR, mseq, false, tostring(packed[2]))
        end
        trace.clear()
    end)
end

--------------------------------------------------------------------------------
-- TCP transport
--------------------------------------------------------------------------------

local function tcp_accept(fd, addr)
    if draining then
        socket.close(fd)
        return
    end
    local s = {
        id = "t" .. fd,
        addr = addr,
        write = function(b) socket.write_frame(fd, b) end,
        close = function() socket.close(fd) end,
    }
    sessions[s.id] = s
    active_connections = active_connections + 1
    metrics.inc("ccserver_connections_total")
    metrics.set("ccserver_connections_active", active_connections)
    socket.start_read_frame(fd)
end

local function tcp_on_message(fd, buf)
    local s = sessions["t" .. fd]
    if s then
        handle_body(s, buffer.unpack(buf, "Z"))
    end
end

local function tcp_on_close(fd)
    local s = sessions["t" .. fd]
    if s then
        close_session(s)
    end
end

--------------------------------------------------------------------------------
-- WebSocket transport
--------------------------------------------------------------------------------

local function ws_conn_loop(conn)
    local s = {
        id = "w" .. conn.id,
        addr = conn.addr,
        write = function(b) conn:write(b) end,
        close = function() conn:close() end,
    }
    sessions[s.id] = s
    active_connections = active_connections + 1
    metrics.inc("ccserver_connections_total")
    metrics.set("ccserver_connections_active", active_connections)

    while not draining do
        local data, kind = conn:read()
        if not data or kind == "c" then
            break
        end
        if kind == "b" or kind == "t" then
            handle_body(s, data)
        end
    end
    if sessions[s.id] then
        close_session(s)
    end
end

local function ws_accept_loop(listener_fd)
    moon.async(function()
        while not draining do
            local conn = websocket.accept(listener_fd)
            if conn then
                moon.async(function() ws_conn_loop(conn) end)
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------------

service.run({
    name = "gateway",
    commands = {
        kick = function(_, uid)
            local id = by_uid[uid]
            if id then
                local s = sessions[id]
                if s then
                    notify(s, MSG.KICK, "account logged in elsewhere")
                    close_session(s)
                end
                return true
            end
            return false, "not online here"
        end,
    },
    on_start = function(self)
        gateway_name = self.name
        gateway_node = self.node
        client_routes = self.client and self.client.routes or nil
        protocol.set_codec(self.codec or "seri")

        local sc = self.config.session or {}
        session_store = session.memory()
        if sc.redis_url then
            moon.async(function()
                local db = require("moon.db")
                local conn_name = "gw_session_" .. tostring(gateway_name)
                local ok = pcall(function()
                    db.setup { redis = { { name = conn_name, url = sc.redis_url } } }
                end)
                if ok then
                    session_store = session.redis(db.redis(conn_name), sc.prefix, sc.ttl)
                    moon.info("gateway: shared session store (redis)")
                else
                    moon.warn("gateway: session redis unavailable, using memory store")
                end
            end)
        end

        local rate = self.config.rate or {}
        rate_per_sec = tonumber(rate.per_sec or os.getenv("CCS_GATEWAY_RATE")) or rate_per_sec
        rate_burst = tonumber(rate.burst or os.getenv("CCS_GATEWAY_BURST")) or rate_burst
        drain_grace_ms = tonumber(self.config.drain_grace_ms) or drain_grace_ms
        worlds = self.config.worlds or { [1] = self.config.world or "world" }

        -- TCP
        socket.on("message", tcp_on_message)
        socket.on("close", tcp_on_close)
        local addr = self.config.addr or os.getenv("CCS_GATEWAY_ADDR") or "0.0.0.0:9001"
        local fd, err = socket.listen(addr, tcp_accept, { max_connections = 100000 })
        if not fd then
            error("gateway: tcp listen failed on " .. addr .. ": " .. tostring(err))
        end
        self.listen_fd = fd

        -- WebSocket (for WeChat mini-games / browsers)
        local ws_addr = self.config.ws_addr or os.getenv("CCS_GATEWAY_WS_ADDR")
        if ws_addr then
            local wfd = websocket.listen(ws_addr, { max_connections = 100000 })
            if not wfd then
                error("gateway: ws listen failed on " .. ws_addr)
            end
            self.ws_listen_fd = wfd
            ws_accept_loop(wfd)
            moon.info("gateway ws listening on " .. ws_addr)
        end

        moon.info(string.format("gateway listening on %s (rate=%d/s burst=%d)", addr, rate_per_sec, rate_burst))
    end,
    on_stop = function(self)
        draining = true
        if self.listen_fd then
            socket.close(self.listen_fd)
            self.listen_fd = nil
        end
        moon.info(string.format("gateway draining (%d active connections)", active_connections))
        if drain_grace_ms > 0 and active_connections > 0 then
            moon.sleep(drain_grace_ms)
        end
        for _, s in pairs(sessions) do
            s.close()
        end
        sessions = {}
        by_uid = {}
        active_connections = 0
    end,
}, ...)

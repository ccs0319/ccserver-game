--- gateway service — client-facing edge.
---
--- Terminates client TCP connections, enforces the wire protocol (version
--- negotiation + framing), manages sessions, and orchestrates the backend
--- service graph (login / lobby / world). It holds **no** auth secrets: it only
--- forwards credentials to `login` and validates the token it issues.
---
--- Protocol: see `ccserver.protocol`. Sessions are bound on ENTER; logging in
--- the same account from a new connection kicks the previous one (顶号).
---
--- Config (topology `services.gateway.config`, or env `CCS_GATEWAY_ADDR`):
---   addr = "0.0.0.0:9001"

local moon = require("moon")
local socket = require("moon.socket")
local buffer = require("buffer")
local service = require("ccserver.service")
local router = require("ccserver.router")
local protocol = require("ccserver.protocol")
local metrics = require("ccserver.metrics")
local trace = require("ccserver.trace")

local MSG = protocol.MSG
local TYPE = protocol.TYPE

---@type table<integer, table> fd -> session
local sessions = {}
---@type table<integer, integer> uid -> fd (active session)
local by_uid = {}
local active_connections = 0

metrics.counter("ccserver_connections_total", "Client connections accepted")
metrics.gauge("ccserver_connections_active", "Currently open client connections")
metrics.counter("ccserver_client_messages_total", "Client messages handled")
metrics.counter("ccserver_errors_total", "Errors returned to clients")
metrics.histogram("ccserver_client_request_seconds", "Client request handling latency")

local function send(fd, mtype, msgid, seq, ...)
    if not sessions[fd] then
        return
    end
    socket.write_frame(fd, protocol.encode(mtype, msgid, seq, ...))
end

local function reply(s, msgid, seq, ok, ...)
    send(s.fd, TYPE.RESPONSE, msgid, seq, ok, ...)
end

local function notify(s, msgid, ...)
    send(s.fd, TYPE.NOTIFY, msgid, 0, ...)
end

local function close_session(fd)
    local s = sessions[fd]
    if not s then
        return
    end
    sessions[fd] = nil
    if s.uid and by_uid[s.uid] == fd then
        by_uid[s.uid] = nil
    end
    socket.close(fd)
end

--------------------------------------------------------------------------------
-- Client command handlers: handler(session, ...args, seq)
--------------------------------------------------------------------------------

local handlers = {}

function handlers.HELLO(s, client_version, seq)
    if client_version ~= protocol.VERSION then
        reply(s, MSG.HELLO_ACK, seq, false,
            string.format("unsupported protocol version %s (server=%d)", tostring(client_version), protocol.VERSION))
        close_session(s.fd)
        return
    end
    s.ver = client_version
    reply(s, MSG.HELLO_ACK, seq, true, protocol.VERSION)
end

function handlers.LOGIN(s, account, password, seq)
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

function handlers.ENTER(s, token, seq)
    if not s.ver then
        reply(s, MSG.ENTER, seq, false, "hello required")
        return
    end
    local auth, err = router.call("login", "verify", token)
    if not auth then
        reply(s, MSG.ENTER, seq, false, err or "auth failed")
        return
    end

    -- 顶号: kick any existing session bound to this uid.
    local old = by_uid[auth.uid]
    if old and old ~= s.fd then
        local old_s = sessions[old]
        if old_s then
            notify(old_s, MSG.KICK, "account logged in elsewhere")
        end
        close_session(old)
    end

    s.uid = auth.uid
    s.token = token
    by_uid[auth.uid] = s.fd

    local lobby = router.call("lobby", "enter", auth.uid)
    local world = router.call("world", "enter", auth.uid, 1)
    reply(s, MSG.ENTER, seq, true,
        { uid = auth.uid, account = auth.account, lobby = lobby, world = world })
end

function handlers.MOVE(s, x, y, seq)
    if not s.uid then
        reply(s, MSG.MOVE, seq, false, "not entered")
        return
    end
    local ok, err = router.call("world", "move", s.uid, x, y)
    reply(s, MSG.MOVE, seq, ok, ok and { x = x, y = y } or err)
end

function handlers.PING(s, seq)
    reply(s, MSG.PING, seq, true, "pong")
end

--------------------------------------------------------------------------------
-- Socket plumbing
--------------------------------------------------------------------------------

local function on_accept(fd, addr)
    sessions[fd] = { fd = fd, addr = addr, ver = nil, uid = nil }
    active_connections = active_connections + 1
    metrics.inc("ccserver_connections_total")
    metrics.set("ccserver_connections_active", active_connections)
    socket.start_read_frame(fd)
end

local function on_close(fd)
    local s = sessions[fd]
    if s and s.uid and by_uid[s.uid] == fd then
        by_uid[s.uid] = nil
    end
    if s then
        active_connections = active_connections - 1
        metrics.set("ccserver_connections_active", active_connections)
    end
    sessions[fd] = nil
end

local function on_message(fd, buf)
    local s = sessions[fd]
    if not s then
        return
    end
    local msg, err = protocol.decode(buffer.unpack(buf, "Z"))
    if not msg then
        notify(s, MSG.ERROR, err)
        close_session(fd)
        return
    end
    if msg.type ~= TYPE.REQUEST then
        return
    end

    local name = protocol.msg_name(msg.msgid)
    local handler = name and handlers[name]
    if not handler then
        metrics.inc("ccserver_errors_total")
        reply(s, MSG.ERROR, msg.seq, false, "unknown msgid: " .. tostring(msg.msgid))
        return
    end
    metrics.inc("ccserver_client_messages_total", 1, { msgid = name })

    -- Handlers may yield (they route to backend services). The socket message
    -- callback itself must not yield, so run the handler in its own coroutine.
    -- Append seq to the args so `table.unpack` (the final argument) expands all.
    local args = msg.args
    args[args.n + 1] = msg.seq
    args.n = args.n + 1
    moon.async(function()
        local tid = trace.start()
        local started = moon.clock()
        local packed = table.pack(xpcall(function()
            return handler(s, table.unpack(args, 1, args.n))
        end, debug.traceback))
        metrics.observe("ccserver_client_request_seconds", moon.clock() - started, { msgid = name })
        if not packed[1] then
            metrics.inc("ccserver_errors_total")
            moon.error(string.format("[trace %s] gateway handler error: %s", tid, tostring(packed[2])))
            reply(s, MSG.ERROR, args[args.n], false, tostring(packed[2]))
        end
        trace.clear()
    end)
end

service.run({
    name = "gateway",
    commands = {}, -- client-facing; no internal RPC commands
    on_start = function(self)
        socket.on("message", on_message)
        socket.on("close", on_close)
        local addr = self.config.addr or os.getenv("CCS_GATEWAY_ADDR") or "0.0.0.0:9001"
        local fd, err = socket.listen(addr, on_accept, { max_connections = 100000 })
        if not fd then
            error("gateway: listen failed on " .. addr .. ": " .. tostring(err))
        end
        self.listen_fd = fd
        moon.info("gateway listening on " .. addr)
    end,
    on_stop = function(self)
        if self.listen_fd then
            socket.close(self.listen_fd)
            self.listen_fd = nil
        end
    end,
}, ...)

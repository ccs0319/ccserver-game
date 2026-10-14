--- ccserver client wire protocol (v1).
---
--- Transport framing is provided by the runtime's socket frame protocol
--- (`socket.write_frame` / `start_read_frame`): `[2-byte BE length][body]`.
--- This module defines the **body** layout and a message registry:
---
--- ```
--- body = [version:u8][type:u8][msgid:u16 BE][seq:u32 BE][payload...]
--- payload = seri.pack(...)   -- binary codec; swap for protobuf later
--- ```
---
--- * `type`   — REQUEST / RESPONSE / NOTIFY
--- * `msgid`  — command id (see `protocol.MSG`); a RESPONSE echoes the request's msgid
--- * `seq`    — client-assigned request sequence; RESPONSE echoes it for correlation
---
--- Unknown/unsupported versions are rejected at the edge (gateway closes the
--- connection after replying an error), so protocol evolution is explicit.

local seri = require("seri")
local json = require("json")

local M = {}

M.VERSION = 1

--- Payload codec: `"seri"` (default, binary, Lua-native) | `"json"` |
--- `"raw"` (payload is opaque bytes; use for protobuf, encoded by the caller).
local codec = "seri"

---@param name string "seri" | "json" | "raw"
function M.set_codec(name)
    assert(name == "seri" or name == "json" or name == "raw", "unknown payload codec: " .. tostring(name))
    codec = name
end

---@return string
function M.codec()
    return codec
end

M.TYPE = {
    REQUEST = 1,
    RESPONSE = 2,
    NOTIFY = 3,
}

--- Message registry. Keep ids stable; add new ones at the end.
M.MSG = {
    HELLO = 1,
    HELLO_ACK = 2,

    LOGIN = 10,
    LOGIN_ACK = 11,
    ENTER = 12,
    ENTER_ACK = 13,
    MOVE = 14,
    MOVE_ACK = 15,
    PING = 16,
    PONG = 17,

    ERROR = 99,
    KICK = 100,
}

local NAME_BY_ID = {}
for name, id in pairs(M.MSG) do
    NAME_BY_ID[id] = name
end

---@param id integer
---@return string|nil
function M.msg_name(id)
    return NAME_BY_ID[id]
end

---@param name string
---@return integer|nil
function M.msg_id(name)
    return M.MSG[name]
end

--- Build the **module message map** from a topology.
---
--- Each service may declare `client = { <client_msg> = <command>, ... }`. The
--- framework assigns a stable msgid to every `"<logical>.<client_msg>"` in a
--- deterministic order (logical names sorted, messages sorted by key) so all
--- nodes agree, and returns a routing table the gateway uses to auto-forward
--- client messages to the owning service.
---
--- If a declaring service belongs to a **group** (e.g. `lobby_1` in
--- `groups.lobby = {lobby_1, lobby_2}`), the route targets the **logical group
--- name** (`lobby`) so the router load-balances; declaring the same message on
--- several instances of one group is de-duplicated.
---
--- ```lua
--- -- topology
--- lobby_1 = { source = "services.lobby", unique = true, client = { get = "get" } }
--- groups  = { lobby = { "lobby_1", "lobby_2" } }
--- -- => id for "lobby.get" routes to service "lobby", cmd "get"
--- ```
---@param cfg table topology
---@param base? integer first module msgid (default 1000)
---@return table `{ routes = id->{service,cmd,name}, ids = name->id, names = id->name, base = base }`
function M.build(cfg, base)
    base = base or 1000
    local routes, ids, names = {}, {}, {}

    -- instance name -> logical (group) name, if any
    local logical = {}
    for gname, instances in pairs(cfg.groups or {}) do
        for _, inst in ipairs(instances) do
            logical[inst] = gname
        end
    end

    local svc_names = {}
    for name, spec in pairs(cfg.services or {}) do
        if type(spec.client) == "table" and next(spec.client) ~= nil then
            svc_names[#svc_names + 1] = name
        end
    end
    table.sort(svc_names)

    local next_id = base
    for _, sname in ipairs(svc_names) do
        local decl = cfg.services[sname].client
        local lname = logical[sname] or sname
        local keys = {}
        for k in pairs(decl) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        ids[lname] = ids[lname] or {}
        for _, k in ipairs(keys) do
            local full = lname .. "." .. k
            if not ids[lname][k] then   -- de-dup across group instances
                routes[next_id] = { service = lname, cmd = decl[k], name = full }
                ids[lname][k] = next_id
                names[next_id] = full
                next_id = next_id + 1
            end
        end
    end

    return { routes = routes, ids = ids, names = names, base = base }
end

--- Look up a module message id: `M.build(cfg).ids[service][msg]`.
---@param map table result of `M.build`
---@param service string logical service name
---@param msg string client message key
---@return integer|nil
function M.module_id(map, service, msg)
    local s = map.ids[service]
    return s and s[msg] or nil
end

local HEADER = ">BBI2I4" -- version, type, msgid, seq  => 8 bytes
local HEADER_SIZE = 8

--- Encode a message body.
---@param mtype integer protocol.TYPE.*
---@param msgid integer
---@param seq integer
---@param ... any payload values (per the configured codec)
---@return string
function M.encode(mtype, msgid, seq, ...)
    local payload
    if codec == "json" then
        payload = json.encode({ ... })
    elseif codec == "raw" then
        payload = (...)
        assert(type(payload) == "string", "raw codec expects a single string payload")
    else
        payload = seri.packstring(...)
    end
    return string.pack(HEADER, M.VERSION, mtype, msgid, seq or 0) .. payload
end

--- Decode a message body.
---@param body string
---@return table|nil msg `{ version, type, msgid, seq, args }`
---@return string|nil err
function M.decode(body)
    if type(body) ~= "string" or #body < HEADER_SIZE then
        return nil, "short frame"
    end
    local version, mtype, msgid, seq = string.unpack(HEADER, body)
    if version ~= M.VERSION then
        return nil, string.format("unsupported protocol version: %s", tostring(version))
    end
    if mtype ~= M.TYPE.REQUEST and mtype ~= M.TYPE.RESPONSE and mtype ~= M.TYPE.NOTIFY then
        return nil, string.format("invalid message type: %s", tostring(mtype))
    end

    local raw = body:sub(HEADER_SIZE + 1)
    local args
    if codec == "json" then
        local ok, decoded = pcall(json.decode, raw)
        if not ok then
            return nil, "bad payload: " .. tostring(decoded)
        end
        if type(decoded) == "table" then
            args = table.pack(table.unpack(decoded))
        else
            args = table.pack(decoded)
        end
    elseif codec == "raw" then
        args = table.pack(raw)
    else
        local r = table.pack(pcall(seri.unpack, raw))
        if not r[1] then
            return nil, "bad payload: " .. tostring(r[2])
        end
        args = table.pack(table.unpack(r, 2, r.n))
    end

    return {
        version = version,
        type = mtype,
        msgid = msgid,
        seq = seq,
        args = args,
    }
end

return M

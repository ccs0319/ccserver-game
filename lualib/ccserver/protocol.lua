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

local M = {}

M.VERSION = 1

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

local HEADER = ">BBI2I4" -- version, type, msgid, seq  => 8 bytes
local HEADER_SIZE = 8

--- Encode a message body.
---@param mtype integer protocol.TYPE.*
---@param msgid integer
---@param seq integer
---@param ... any payload values (seri-encoded)
---@return string
function M.encode(mtype, msgid, seq, ...)
    local payload = seri.packstring(...)
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
    local args = table.pack(pcall(seri.unpack, body:sub(HEADER_SIZE + 1)))
    if not args[1] then
        return nil, "bad payload: " .. tostring(args[2])
    end
    return {
        version = version,
        type = mtype,
        msgid = msgid,
        seq = seq,
        args = table.pack(table.unpack(args, 2, args.n)),
    }
end

return M

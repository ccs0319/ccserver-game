--- Coroutine-local trace ids.
---
--- Assign a trace id at an entry point (e.g. the gateway, per client request) and
--- read it deeper in the call stack for correlated logging. The id is stored per
--- coroutine, so concurrent requests don't clash.
---
--- ```lua
--- local trace = require("ccserver.trace")
--- local id = trace.start()          -- or trace.start(client_seq)
--- moon.info("[" .. id .. "] handling request")
--- trace.clear()
--- ```

local M = {}

local counter = 0
local current = setmetatable({}, { __mode = "k" }) -- coroutine -> id

---@return string
local function generate()
    counter = counter + 1
    return string.format("%x-%x", os.time(), counter)
end

--- Set (and return) the trace id for the current coroutine.
---@param id? string
---@return string
function M.start(id)
    id = id or generate()
    current[coroutine.running()] = id
    return id
end

---@return string|nil
function M.current()
    return current[coroutine.running()]
end

function M.clear()
    current[coroutine.running()] = nil
end

--- Run `fn(...)` with a fresh (or given) trace id, clearing it afterwards.
---@param id? string
---@param fn function
---@return any ...
function M.with(id, fn, ...)
    M.start(id)
    local r = table.pack(pcall(fn, ...))
    M.clear()
    if not r[1] then
        error(r[2])
    end
    return table.unpack(r, 2, r.n)
end

return M

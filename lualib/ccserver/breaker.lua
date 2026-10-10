--- Circuit breaker.
---
--- Tracks failures per key (typically a downstream service). After
--- `threshold` consecutive failures the breaker opens and fails fast for
--- `cooldown` seconds; then it half-opens, allowing a trial call — success
--- closes it, failure re-opens it.
---
--- ```lua
--- local breaker = require("ccserver.breaker")
--- local ok, res = breaker.call("login", function() return router.call("login", "verify", t) end)
--- ```

local moon = require("moon")

local M = {}

local DEFAULT_THRESHOLD = 5
local DEFAULT_COOLDOWN = 5 -- seconds

---@type table<string, {state:string, failures:number, opened_at:number}>
local breakers = {}

local function get(key)
    local b = breakers[key]
    if not b then
        b = { state = "closed", failures = 0, opened_at = 0 }
        breakers[key] = b
    end
    return b
end

--- Is a call permitted right now? Transitions open -> half_open after cooldown.
---@param key string
---@param cooldown? number seconds
---@return boolean
function M.allow(key, cooldown)
    cooldown = cooldown or DEFAULT_COOLDOWN
    local b = get(key)
    if b.state == "open" then
        if moon.clock() - b.opened_at >= cooldown then
            b.state = "half_open"
            return true
        end
        return false
    end
    return true
end

---@param key string
function M.record_success(key)
    local b = get(key)
    b.state = "closed"
    b.failures = 0
end

---@param key string
---@param threshold? number
function M.record_failure(key, threshold)
    threshold = threshold or DEFAULT_THRESHOLD
    local b = get(key)
    b.failures = b.failures + 1
    if b.state == "half_open" or b.failures >= threshold then
        b.state = "open"
        b.opened_at = moon.clock()
    end
end

--- Current state: "closed" | "open" | "half_open".
---@param key string
---@return string
function M.state(key)
    return get(key).state
end

--- Run `fn(...)` guarded by the breaker. Returns `false, "circuit open"` when
--- the breaker is open; records success/failure otherwise.
---@param key string
---@param fn function
---@param opts? table `{ threshold, cooldown }`
---@return any ...
function M.call(key, fn, opts)
    opts = opts or {}
    if not M.allow(key, opts.cooldown) then
        return false, "circuit open: " .. tostring(key)
    end
    local r = table.pack(pcall(fn))
    if r[1] and r[2] ~= false then
        M.record_success(key)
    else
        M.record_failure(key, opts.threshold)
    end
    if not r[1] then
        return false, r[2]
    end
    return table.unpack(r, 2, r.n)
end

---@param key string
function M.reset(key)
    breakers[key] = nil
end

return M

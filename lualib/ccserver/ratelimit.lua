--- Token-bucket rate limiter.
---
--- Per-key buckets; `allow` consumes tokens if available. Use one key per
--- connection, per uid, or per command as needed.
---
--- ```lua
--- local ratelimit = require("ccserver.ratelimit")
--- if not ratelimit.allow("fd:" .. fd, 20, 40) then   -- 20/s, burst 40
---     -- too fast
--- end
--- ```

local moon = require("moon")

local M = {}

---@type table<string, {tokens:number, last:number}>
local buckets = {}

--- Try to consume `n` tokens for `key`.
---@param key string
---@param rate number tokens refilled per second
---@param burst number bucket capacity
---@param now? number seconds (defaults to `moon.clock()`)
---@param n? number tokens to consume (default 1)
---@return boolean allowed
function M.allow(key, rate, burst, now, n)
    now = now or moon.clock()
    n = n or 1
    local b = buckets[key]
    if not b then
        b = { tokens = burst, last = now }
        buckets[key] = b
    else
        b.tokens = math.min(burst, b.tokens + (now - b.last) * rate)
        b.last = now
    end
    if b.tokens >= n then
        b.tokens = b.tokens - n
        return true
    end
    return false
end

--- Drop a key's bucket (e.g. on disconnect).
---@param key string
function M.reset(key)
    buckets[key] = nil
end

--- Number of tracked keys.
---@return integer
function M.size()
    local n = 0
    for _ in pairs(buckets) do
        n = n + 1
    end
    return n
end

return M

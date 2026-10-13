--- Shared session store for stateless gateways.
---
--- A gateway keeps its live connections locally, but **session ownership**
--- (`uid -> { gateway, node, zone, ts }`) lives in a shared backend so any
--- gateway can see who owns a uid and kick it across processes.
---
--- Backends:
---   * `session.memory()`      — per-actor, single-gateway dev
---   * `session.redis(conn)`   — shared, production (Redis + TTL)
---
--- ```lua
--- local session = require("ccserver.session")
--- local store = session.redis(db.redis("cache"), "ccserver:session:", 3600)
--- local prev = store.get(uid)
--- if prev and prev.gateway ~= self.name then router.call(prev.gateway, "kick", uid) end
--- store.set(uid, { gateway = self.name, node = self.node, zone = zone, ts = os.time() })
--- ```

local json = require("json")

local M = {}

--- Per-actor in-memory backend (not shared across actors/nodes).
---@return table
function M.memory()
    local store = {}
    return {
        kind = "memory",
        get = function(uid)
            return store[tostring(uid)]
        end,
        set = function(uid, owner)
            store[tostring(uid)] = owner
        end,
        del = function(uid, gateway)
            local cur = store[tostring(uid)]
            if cur and (not gateway or cur.gateway == gateway) then
                store[tostring(uid)] = nil
            end
        end,
    }
end

--- Redis-backed shared backend.
---@param conn table a `moon.db.redis` connection
---@param prefix? string defaults to "ccserver:session:"
---@param ttl? integer seconds defaults to 3600
---@return table
function M.redis(conn, prefix, ttl)
    prefix = prefix or "ccserver:session:"
    ttl = ttl or 3600
    local function key(uid)
        return prefix .. tostring(uid)
    end
    return {
        kind = "redis",
        get = function(uid)
            local v = conn:get(key(uid))
            if v then
                local ok, o = pcall(json.decode, v)
                if ok then
                    return o
                end
            end
            return nil
        end,
        set = function(uid, owner)
            conn:set(key(uid), json.encode(owner))
            conn:expire(key(uid), ttl)
        end,
        del = function(uid, gateway)
            local v = conn:get(key(uid))
            if not v then
                return
            end
            local ok, o = pcall(json.decode, v)
            if not ok or not gateway or (o and o.gateway == gateway) then
                conn:del(key(uid))
            end
        end,
    }
end

return M

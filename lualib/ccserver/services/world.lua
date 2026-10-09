--- world service (reference implementation).
---
--- Owns in-game state for a zone/line: entities, positions, AOI (see the
--- `moon-game` crate for the pure-Rust AOI algorithms). A real deployment shards
--- the world into many instances (`world_1`, `world_2`, ...), each a node/service.

local moon = require("moon")
local service = require("ccserver.service")

local entities = {}

local commands = {}

--- Enter the world in a zone.
---@param uid integer
---@param zone? integer
---@return table entity
function commands.enter(self, uid, zone)
    local entity = { uid = uid, zone = zone or 1, x = 0, y = 0 }
    entities[uid] = entity
    return entity
end

--- Move an entity.
---@param uid integer
---@param x number
---@param y number
---@return boolean|boolean ok, string? err
function commands.move(self, uid, x, y)
    local entity = entities[uid]
    if not entity then
        return false, "entity not in world"
    end
    entity.x, entity.y = x, y
    return true
end

--- Leave the world.
---@param uid integer
---@return boolean
function commands.leave(self, uid)
    entities[uid] = nil
    return true
end

--- Get an entity snapshot.
---@param uid integer
---@return table|nil
function commands.get(self, uid)
    return entities[uid]
end

service.run({
    name = "world",
    commands = commands,
    on_start = function()
        moon.info("world service ready")
    end,
}, ...)

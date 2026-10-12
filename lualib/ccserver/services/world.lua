--- world service (reference implementation).
---
--- Owns in-game state for one **zone/line shard**: entities, positions, AOI (see
--- the `moon-game` crate for the pure-Rust AOI algorithms). A deployment runs
--- many shards (`world_1`, `world_2`, ...), each a service (optionally on a
--- different node). The shard's zone comes from its config:
---
---   world_2 = { source = "ccserver.services.world", unique = true,
---               config = { zone = 2 } }

local moon = require("moon")
local service = require("ccserver.service")

local entities = {}

local commands = {}

--- Enter this shard.
---@param uid integer
---@param zone? integer must match this shard's zone if given
---@return table|boolean entity, string? err
function commands.enter(self, uid, zone)
    local shard_zone = self.config.zone or 1
    if zone and zone ~= shard_zone then
        return false, string.format("wrong shard: zone %s != %s", tostring(zone), tostring(shard_zone))
    end
    local entity = { uid = uid, zone = shard_zone, x = 0, y = 0 }
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
    on_start = function(self)
        moon.info(string.format("world shard ready (zone=%s)", tostring(self.config.zone or 1)))
    end,
}, ...)

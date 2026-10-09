--- lobby service (reference implementation).
---
--- Player-facing social/entry layer: profile, friends, matchmaking, chat live
--- here (this skeleton keeps an in-memory session table). The lobby is typically
--- stateless enough to scale horizontally.

local moon = require("moon")
local service = require("ccserver.service")

local sessions = {}

local commands = {}

--- Enter the lobby for a player.
---@param uid integer
---@return table
function commands.enter(self, uid)
    sessions[uid] = { uid = uid, channel = "lobby", since = os.time() }
    return sessions[uid]
end

--- Leave the lobby.
---@param uid integer
---@return boolean
function commands.leave(self, uid)
    sessions[uid] = nil
    return true
end

--- Get a player's lobby session (nil if not present).
---@param uid integer
---@return table|nil
function commands.get(self, uid)
    return sessions[uid]
end

service.run({
    name = "lobby",
    commands = commands,
    on_start = function()
        moon.info("lobby service ready")
    end,
}, ...)

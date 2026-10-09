--- gateway service (reference implementation).
---
--- The client-facing entry point. In a full deployment the gateway terminates
--- client connections (TCP/KCP/WebSocket), frames/validates/rate-limits packets
--- and binds a session to a player; here it demonstrates the service graph by
--- orchestrating login -> lobby -> world through the router.
---
--- Note: the gateway NEVER handles credentials itself beyond forwarding them to
--- the login service, and it never holds auth secrets.

local moon = require("moon")
local service = require("ccserver.service")
local router = require("ccserver.router")

local commands = {}

--- Client login: forward credentials to the login service.
---@param account string
---@param password string
---@return table|boolean
function commands.login(self, account, password)
    return router.call("login", "login", account, password)
end

--- Client enters the game: verify the token, then join lobby and world.
---@param token string
---@return table|boolean session
function commands.enter(self, token)
    local auth, err = router.call("login", "verify", token)
    if not auth then
        return false, err or "auth failed"
    end

    local lobby = router.call("lobby", "enter", auth.uid)
    local world = router.call("world", "enter", auth.uid, 1)
    return { uid = auth.uid, account = auth.account, lobby = lobby, world = world }
end

--- Client move: route to the world service.
---@param uid integer
---@param x number
---@param y number
---@return boolean|boolean
function commands.move(self, uid, x, y)
    return router.call("world", "move", uid, x, y)
end

service.run({
    name = "gateway",
    commands = commands,
    on_start = function()
        moon.info("gateway service ready")
    end,
}, ...)

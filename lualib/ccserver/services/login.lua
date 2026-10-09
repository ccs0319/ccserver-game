--- login service (reference implementation).
---
--- Owns account authentication and session-token issuance. In a real deployment
--- this is the ONLY place that holds auth secrets / talks to third-party SDKs;
--- other services never see credentials, only the issued token.

local moon = require("moon")
local service = require("ccserver.service")

local accounts = {}
local next_uid = 1000

local commands = {}

--- Authenticate an account and issue a session token.
---@param account string
---@param password string
---@return table|boolean result `{ uid, account, token }` or `false, err`
function commands.login(self, account, password)
    if type(account) ~= "string" or account == "" then
        return false, "missing account"
    end
    if type(password) ~= "string" or password == "" then
        return false, "missing password"
    end

    local uid = accounts[account]
    if not uid then
        uid = next_uid
        next_uid = next_uid + 1
        accounts[account] = uid
    end

    local token = string.format("%s:%d:%d", account, uid, os.time())
    return { uid = uid, account = account, token = token }
end

--- Validate a session token.
---@param token string
---@return table|boolean result `{ uid, account }` or `false, err`
function commands.verify(self, token)
    local account, uid = tostring(token or ""):match("^([^:]+):(%d+):")
    if not account then
        return false, "invalid token"
    end
    return { uid = tonumber(uid), account = account }
end

service.run({
    name = "login",
    commands = commands,
    on_start = function()
        moon.info("login service ready")
    end,
}, ...)

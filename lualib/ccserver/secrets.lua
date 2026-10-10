--- Secret loading with a no-leak logging helper.
---
--- Secrets are never committed to config files. Resolve them at runtime from
--- the environment (preferred) or a file outside version control:
---
---   1. explicit env var name (`opts.env`)
---   2. `CCS_SECRET_<KEY>` (key upper-cased, non-alphanumerics -> `_`)
---   3. a file (`opts.file`, or `opts.dir .. "/" .. key`)
---
--- ```lua
--- local secrets = require("ccserver.secrets")
--- local db_password = secrets.get("db_password", { dir = "/run/secrets" })
--- moon.info("db password = " .. secrets.redact(db_password))   -- never log the value
--- ```

local fs = require("fs")

local M = {}

local function env_name(key)
    return "CCS_SECRET_" .. tostring(key):upper():gsub("[^%w]", "_")
end

---@param key string
---@param opts? table `{ env, file, dir }`
---@return string|nil
function M.get(key, opts)
    opts = opts or {}

    local explicit = opts.env and os.getenv(opts.env)
    if explicit and explicit ~= "" then
        return explicit
    end

    local implicit = os.getenv(env_name(key))
    if implicit and implicit ~= "" then
        return implicit
    end

    local path = opts.file or (opts.dir and (opts.dir .. "/" .. key))
    if path and fs.exists(path) then
        return (io.readfile(path):gsub("%s+$", ""))
    end

    return nil
end

--- A safe placeholder for logging (never the value itself).
---@param value any
---@return string
function M.redact(value)
    if value == nil then
        return "<unset>"
    end
    return string.format("<redacted:%d chars>", #tostring(value))
end

return M

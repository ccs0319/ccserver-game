--- Schema migration runner for `moon.db.sqlx` (backend-agnostic).
---
--- Applies ordered migration files from a directory and records each applied
--- version in a `schema_migrations` table, so restarts only run the delta.
---
--- Migration files are named `NNNN_description.lua` (or `.sql`), e.g.
--- `0001_init.lua`. The `NNNN` prefix is the version and MUST be zero-padded so
--- lexical sort equals numeric order.
---
--- A `.lua` migration returns a **list of SQL statement strings**:
---
--- ```lua
--- -- 0001_init.lua
--- return {
---     [[CREATE TABLE player (
---         uid   BIGINT PRIMARY KEY,
---         name  VARCHAR(64) NOT NULL,
---         level INT NOT NULL DEFAULT 1
---     )]],
--- }
--- ```
---
--- A `.sql` file is split on `;` (statements must not contain `;` inside string
--- literals). Prefer `.lua` for anything non-trivial.
---
--- **Atomicity:** statements run one-by-one (not wrapped in a transaction)
--- because MySQL DDL causes an implicit commit. A failing migration stops the
--- run and leaves earlier statements applied; fix forward with a new migration.

local fs = require("fs")

local M = {}

local TABLE = "schema_migrations"

local function is_error(res)
    return type(res) == "table" and res.kind ~= nil
end

-- Single-quote a controlled string for inlining (version/name/timestamp only).
local function q(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function ensure_table(db)
    local res = db:query(string.format([[
        CREATE TABLE IF NOT EXISTS %s (
            version    VARCHAR(64) PRIMARY KEY,
            name       VARCHAR(255),
            applied_at VARCHAR(32)
        )]], TABLE))
    if is_error(res) then
        error("migration: create tracking table failed: " .. tostring(res.message))
    end
end

local function applied_set(db)
    local res = db:query("SELECT version FROM " .. TABLE)
    if is_error(res) then
        error("migration: read applied versions failed: " .. tostring(res.message))
    end
    local set = {}
    for _, row in ipairs(res) do
        set[tostring(row.version)] = true
    end
    return set
end

local function load_statements(path)
    local ext = path:match("%.([%a%d]+)$")
    if ext == "lua" then
        local chunk = assert(load(io.readfile(path), "@" .. path), "migration: cannot load " .. path)
        local body = chunk()
        if type(body) == "table" and body.up then
            body = body.up
        end
        assert(type(body) == "table", "migration: " .. path .. " must return a list of statements")
        return body
    elseif ext == "sql" then
        local text = io.readfile(path)
        local stmts = {}
        for raw in text:gmatch("([^;]+);?") do
            local stmt = raw:match("^%s*(.-)%s*$")
            if stmt ~= "" then
                stmts[#stmts + 1] = stmt
            end
        end
        return stmts
    end
    error("migration: unsupported file " .. path)
end

local function list_migrations(dir)
    local migs = {}
    for _, path in ipairs(fs.listdir(dir, 1)) do
        local filename = path:match("([^/\\]+)$")
        local version, name = filename:match("^(%d+)_(.+)%.[%a%d]+$")
        if version then
            migs[#migs + 1] = { version = version, name = name, path = path }
        end
    end
    table.sort(migs, function(a, b) return a.version < b.version end)
    return migs
end

--- Apply all pending migrations under `dir`.
---@async
---@param db sqlx an already-connected `moon.db.sqlx` connection
---@param dir string directory containing migration files
---@return string[] applied list of `NNNN_name` applied this run
function M.run(db, dir)
    ensure_table(db)
    local applied = applied_set(db)
    local ran = {}
    for _, m in ipairs(list_migrations(dir)) do
        if not applied[m.version] then
            local stmts = load_statements(m.path)
            for i, stmt in ipairs(stmts) do
                local res = db:query(stmt)
                if is_error(res) then
                    error(string.format("migration %s_%s statement %d failed: %s",
                        m.version, m.name, i, tostring(res.message)))
                end
            end
            local rec = db:query(string.format(
                "INSERT INTO %s (version, name, applied_at) VALUES (%s, %s, %s)",
                TABLE, q(m.version), q(m.name), q(os.date("%Y-%m-%d %H:%M:%S"))))
            if is_error(rec) then
                error("migration: record " .. m.version .. " failed: " .. tostring(rec.message))
            end
            ran[#ran + 1] = m.version .. "_" .. m.name
        end
    end
    return ran
end

--- List applied migrations (ascending).
---@async
---@param db sqlx
---@return table rows `{ { version, name, applied_at }, ... }`
function M.status(db)
    ensure_table(db)
    local res = db:query("SELECT version, name, applied_at FROM " .. TABLE .. " ORDER BY version")
    if is_error(res) then
        error("migration: status failed: " .. tostring(res.message))
    end
    return res
end

return M

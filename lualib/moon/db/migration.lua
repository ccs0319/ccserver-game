--- Schema migration runner for `moon.db.sqlx` (backend-agnostic).
---
--- Applies ordered migration files from a directory and records each applied
--- version, name and **checksum** in `schema_migrations`, so restarts only run
--- the delta and edits to already-applied migrations are detected.
---
--- Migration files are named `NNNN_description.lua` (or `.sql`). The `NNNN`
--- prefix is the version and MUST be zero-padded so lexical sort equals numeric.
---
--- A `.lua` migration returns a **list of up statements**, or
--- `{ up = {...}, down = {...} }` to support `rollback`:
---
--- ```lua
--- return {
---     up = { [[CREATE TABLE player (uid BIGINT PRIMARY KEY, name TEXT)]] },
---     down = { [[DROP TABLE player]] },
--- }
--- ```
---
--- Concurrency: `run` takes a backend advisory lock (MySQL `GET_LOCK`, PostgreSQL
--- `pg_advisory_lock`) when `opts.backend` is given, so two nodes starting at
--- once cannot both apply migrations. SQLite/unknown backends run lock-free.
---
--- **Atomicity:** statements run one-by-one (not wrapped in a transaction)
--- because MySQL DDL causes an implicit commit. A failing migration stops the
--- run; fix forward with a new migration.

local fs = require("fs")

local M = {}

local TABLE = "schema_migrations"
local LOCK_NAME = "ccserver_schema_migration"
local LOCK_KEY = 727274

local function is_error(res)
    return type(res) == "table" and res.kind ~= nil
end

-- Single-quote a controlled string for inlining (version/name/checksum only).
local function q(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

-- Stable, dependency-free content hash (djb2) for tamper/edit detection.
local function checksum(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

local function ensure_table(db)
    local res = db:query(string.format([[
        CREATE TABLE IF NOT EXISTS %s (
            version    VARCHAR(64) PRIMARY KEY,
            name       VARCHAR(255),
            checksum   VARCHAR(64),
            applied_at VARCHAR(32)
        )]], TABLE))
    if is_error(res) then
        error("migration: create tracking table failed: " .. tostring(res.message))
    end
    -- Upgrade older tracking tables that lack the checksum column.
    local probe = db:query("SELECT checksum FROM " .. TABLE .. " LIMIT 1")
    if is_error(probe) then
        db:query("ALTER TABLE " .. TABLE .. " ADD COLUMN checksum VARCHAR(64)")
    end
end

local function acquire_lock(db, backend)
    if backend == "mysql" then
        db:query(string.format("SELECT GET_LOCK('%s', 10)", LOCK_NAME))
    elseif backend == "postgres" then
        db:query(string.format("SELECT pg_advisory_lock(%d)", LOCK_KEY))
    end
end

local function release_lock(db, backend)
    if backend == "mysql" then
        db:query(string.format("SELECT RELEASE_LOCK('%s')", LOCK_NAME))
    elseif backend == "postgres" then
        db:query(string.format("SELECT pg_advisory_unlock(%d)", LOCK_KEY))
    end
end

local function load_file(path)
    local content = io.readfile(path)
    local ext = path:match("%.([%a%d]+)$")
    if ext == "lua" then
        local chunk = assert(load(content, "@" .. path), "migration: cannot load " .. path)
        local body = chunk()
        if type(body) == "table" and body.up then
            return body.up, body.down, content
        end
        assert(type(body) == "table", "migration: " .. path .. " must return a list of statements")
        return body, nil, content
    elseif ext == "sql" then
        local stmts = {}
        for raw in content:gmatch("([^;]+);?") do
            local stmt = raw:match("^%s*(.-)%s*$")
            if stmt ~= "" then
                stmts[#stmts + 1] = stmt
            end
        end
        return stmts, nil, content
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

local function applied_map(db)
    local res = db:query("SELECT version, checksum FROM " .. TABLE)
    if is_error(res) then
        error("migration: read applied versions failed: " .. tostring(res.message))
    end
    local map = {}
    for _, row in ipairs(res) do
        map[tostring(row.version)] = row.checksum and tostring(row.checksum) or nil
    end
    return map
end

local function apply_statements(db, stmts, label)
    for i, stmt in ipairs(stmts) do
        local res = db:query(stmt)
        if is_error(res) then
            error(string.format("%s statement %d failed: %s", label, i, tostring(res.message)))
        end
    end
end

--- Apply all pending migrations under `dir`.
---@async
---@param db sqlx an already-connected `moon.db.sqlx` connection
---@param dir string directory containing migration files
---@param opts? table `{ backend = "mysql"|"postgres"|"sqlite" }` (enables advisory lock)
---@return string[] applied list of `NNNN_name` applied this run
function M.run(db, dir, opts)
    opts = opts or {}
    ensure_table(db)
    acquire_lock(db, opts.backend)

    local ok, result = pcall(function()
        local applied = applied_map(db)
        local ran = {}
        for _, m in ipairs(list_migrations(dir)) do
            if not applied[m.version] then
                local up, _, content = load_file(m.path)
                apply_statements(db, up, string.format("migration %s_%s", m.version, m.name))
                local rec = db:query(string.format(
                    "INSERT INTO %s (version, name, checksum, applied_at) VALUES (%s, %s, %s, %s)",
                    TABLE, q(m.version), q(m.name), q(checksum(content)), q(os.date("%Y-%m-%d %H:%M:%S"))))
                if is_error(rec) then
                    error("migration: record " .. m.version .. " failed: " .. tostring(rec.message))
                end
                ran[#ran + 1] = m.version .. "_" .. m.name
            end
        end
        return ran
    end)

    release_lock(db, opts.backend)
    if not ok then
        error(result)
    end
    return result
end

--- Verify that applied migrations still match their files (no silent edits).
---@async
---@param db sqlx
---@param dir string
---@return table mismatches `{ { version, expected, actual } }`
function M.verify(db, dir)
    ensure_table(db)
    local applied = applied_map(db)
    local mismatches = {}
    for _, m in ipairs(list_migrations(dir)) do
        local recorded = applied[m.version]
        if recorded then
            local _, _, content = load_file(m.path)
            local actual = checksum(content)
            if recorded ~= actual then
                mismatches[#mismatches + 1] = { version = m.version, expected = recorded, actual = actual }
            end
        end
    end
    return mismatches
end

--- Roll back the last `n` applied migrations (default 1) using their `down`.
---@async
---@param db sqlx
---@param dir string
---@param n? integer
---@param opts? table `{ backend = ... }`
---@return string[] rolled_back
function M.rollback(db, dir, n, opts)
    opts = opts or {}
    n = n or 1
    ensure_table(db)
    acquire_lock(db, opts.backend)

    local ok, result = pcall(function()
        local applied = applied_map(db)
        local migs = list_migrations(dir)
        local rolled = {}
        for i = #migs, 1, -1 do
            local m = migs[i]
            if applied[m.version] and #rolled < n then
                local _, down, _ = load_file(m.path)
                if not down then
                    error(string.format("migration %s_%s has no `down`", m.version, m.name))
                end
                apply_statements(db, down, string.format("rollback %s_%s", m.version, m.name))
                db:query(string.format("DELETE FROM %s WHERE version = %s", TABLE, q(m.version)))
                rolled[#rolled + 1] = m.version .. "_" .. m.name
            end
        end
        return rolled
    end)

    release_lock(db, opts.backend)
    if not ok then
        error(result)
    end
    return result
end

--- List applied migrations (ascending).
---@async
---@param db sqlx
---@return table rows `{ { version, name, checksum, applied_at }, ... }`
function M.status(db)
    ensure_table(db)
    local res = db:query("SELECT version, name, checksum, applied_at FROM " .. TABLE .. " ORDER BY version")
    if is_error(res) then
        error("migration: status failed: " .. tostring(res.message))
    end
    return res
end

return M

--- etcd-backed node registry (production service discovery).
---
--- Nodes register their cluster address under `<prefix><node_id>` with an etcd
--- **lease** and keep it alive; when a node dies its lease expires and the key
--- disappears. A small HTTP adapter (`discovery.serve`) exposes the same
--- `GET /cluster?node=N -> host:port` contract the native cluster module expects,
--- backed by etcd.
---
--- ```lua
--- local discovery = require("ccserver.discovery")
--- local reg = discovery.registry({ endpoint = "http://127.0.0.1:2379" })
--- reg:register(1, "127.0.0.1:42345")     -- lease + keepalive
--- reg:resolve(1)                          -- -> "127.0.0.1:42345"
--- discovery.serve(reg, "0.0.0.0:9090")    -- HTTP adapter for cluster.init
--- ```

local moon = require("moon")
local fs = require("fs")
local protobuf = require("protobuf")
local etcd = require("moon.db.etcd")

local M = {}

local proto_loaded = false

-- Candidate descriptor paths across common working directories.
local PROTO_CANDIDATES = {
    "grpc/etcd.pb",
    "../example/grpc/etcd.pb",
    "../assets/example/grpc/etcd.pb",
    "assets/example/grpc/etcd.pb",
}

local function ensure_proto(path)
    if proto_loaded then
        return
    end
    local candidates = path and { path } or PROTO_CANDIDATES
    for _, p in ipairs(candidates) do
        if fs.exists(p) then
            protobuf.load(io.readfile(p))
            proto_loaded = true
            return
        end
    end
    error("discovery: etcd proto descriptor not found (tried " .. table.concat(candidates, ", ") .. ")")
end

local Registry = {}
Registry.__index = Registry

--- Create an etcd-backed registry. Must be called inside `moon.async`.
---@param opts? table `{ endpoint?, prefix?, ttl?, proto?, name? }`
---@return table|nil registry
---@return string|nil err
function M.registry(opts)
    opts = opts or {}
    ensure_proto(opts.proto)
    local name = opts.name or "ccserver-discovery"
    local client, err = etcd.connect({
        endpoint = opts.endpoint or "http://127.0.0.1:2379",
        name = name,
    })
    if not client then
        return nil, err
    end
    return setmetatable({
        client = client,
        name = name,
        prefix = opts.prefix or "/ccserver/nodes/",
        ttl = opts.ttl or 10,
        leases = {},
    }, Registry)
end

---@param node_id integer|string
---@return string
function Registry:key(node_id)
    return self.prefix .. tostring(node_id)
end

--- Register (or update) a node address with a lease; starts keep-alive.
---@param node_id integer
---@param addr string
---@return boolean ok
---@return string? err
function Registry:register(node_id, addr)
    local entry = self.leases[node_id]
    if entry then
        self.client:put(self:key(node_id), addr, { lease = entry.id })
        entry.addr = addr
        return true
    end
    local grant = self.client:lease_grant(self.ttl)
    if not grant then
        return false, "lease_grant failed"
    end
    if not self.client:put(self:key(node_id), addr, { lease = grant.ID }) then
        return false, "etcd put failed"
    end
    self.leases[node_id] = {
        id = grant.ID,
        stream = self.client:lease_keep_alive(grant.ID),
        addr = addr,
    }
    self:start_keepalive()
    return true
end

---@param node_id integer|string
---@return string|nil addr
function Registry:resolve(node_id)
    local resp = self.client:range(self:key(node_id))
    if resp and resp.count and resp.count > 0 and resp.kvs and resp.kvs[1] then
        return resp.kvs[1].value
    end
    return nil
end

--- List all registered nodes (`node_id -> addr`).
---@return table<string, string>
function Registry:list()
    local out = {}
    local resp = self.client:range(self.prefix, etcd.prefix_end(self.prefix))
    for _, kv in ipairs((resp and resp.kvs) or {}) do
        local id = tostring(kv.key):sub(#self.prefix + 1)
        out[id] = kv.value
    end
    return out
end

---@param node_id integer|string
function Registry:unregister(node_id)
    local entry = self.leases[node_id]
    if entry then
        pcall(function() entry.stream:close() end)
        self.client:lease_revoke(entry.id)
        self.leases[node_id] = nil
    else
        self.client:delete(self:key(node_id))
    end
end

function Registry:start_keepalive()
    if self._ka then
        return
    end
    self._ka = true
    local interval = math.max(1, math.floor(self.ttl / 3)) * 1000
    moon.async(function()
        while self._ka do
            moon.sleep(interval)
            for _, entry in pairs(self.leases) do
                if entry.stream:send() then
                    entry.stream:recv()
                end
            end
        end
    end)
end

function Registry:close()
    self._ka = false
    for _, entry in pairs(self.leases) do
        pcall(function() entry.stream:close() end)
    end
    self.leases = {}
    etcd.close(self.name)
end

--------------------------------------------------------------------------------
-- HTTP adapter: expose etcd to the native cluster module's discovery contract.
--------------------------------------------------------------------------------

local function parse_query(qs)
    local out = {}
    for k, v in tostring(qs or ""):gmatch("([^&=]+)=([^&=]*)") do
        out[k] = v
    end
    return out
end

--- Serve `GET /cluster?node=N -> host:port` (and `GET /nodes` for inspection).
---@param registry table
---@param addr string
---@return integer listener_fd
function M.serve(registry, addr)
    local httpd = require("moon.httpd")
    local core = require("httpd.core")

    local listen_fd = httpd.listen(addr)
    moon.dispatch("httpd", function(_, _, req, handle)
        moon.async(function()
            local query = parse_query(req.query_string)
            local status, headers, body
            if req.path == "/cluster" then
                local resolved = query.node and registry:resolve(query.node) or nil
                if resolved then
                    status, headers, body = 200, { ["Content-Type"] = "text/plain" }, resolved
                else
                    status, headers, body = 404, { ["Content-Type"] = "text/plain" },
                        "node not found: " .. tostring(query.node)
                end
            elseif req.path == "/nodes" then
                status, headers, body = 200, { ["Content-Type"] = "application/json" },
                    require("json").encode(registry:list())
            else
                status, headers, body = 404, { ["Content-Type"] = "text/plain" }, "not found\n"
            end
            core.response(handle, status, headers, body)
        end)
    end)
    moon.info("discovery adapter (etcd) listening on " .. addr)
    return listen_fd
end

return M

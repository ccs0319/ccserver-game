--- admin service — observability endpoints.
---
--- Serves HTTP probes for the process:
---   * `GET /health`  — liveness (always 200 while the process is up)
---   * `GET /ready`   — readiness: all registered checks pass (503 otherwise)
---   * `GET /metrics` — Prometheus text; aggregates every local service's metrics
---   * `GET /stats`   — runtime stats JSON (`moon.server_stats()`)
---
--- Config (`services.admin.config` or env `CCS_ADMIN_ADDR`):
---   addr = "0.0.0.0:9002"
---   required_services = { "gateway", "login", "lobby", "world" }  -- readiness

local moon = require("moon")
local httpd = require("moon.httpd")
local core = require("httpd.core")
local json = require("json")
local service = require("ccserver.service")
local router = require("ccserver.router")
local metrics = require("ccserver.metrics")
local health = require("ccserver.health")

--- Merge several Prometheus texts, keeping the first HELP/TYPE for each name.
local function merge_metrics(texts)
    local out = {}
    local seen = {}
    for _, text in ipairs(texts) do
        for line in text:gmatch("[^\n]+") do
            local name = line:match("^# %u+ (%S+)")
            if name then
                if not seen[name] then
                    seen[name] = true
                    out[#out + 1] = line
                end
            else
                out[#out + 1] = line
            end
        end
    end
    return table.concat(out, "\n") .. "\n"
end

local function handle_request(self, req)
    local path = req.path
    if path == "/health" then
        return 200, { ["Content-Type"] = "text/plain" }, "ok\n"
    elseif path == "/ready" then
        local ok, results = health.run()
        return ok and 200 or 503,
            { ["Content-Type"] = "application/json" },
            json.encode({ ok = ok, checks = results })
    elseif path == "/metrics" then
        local texts = { metrics.render() }
        for name in pairs(router.services()) do
            if name ~= self.name then
                local rendered = router.call(name, "metrics")
                if type(rendered) == "string" then
                    texts[#texts + 1] = rendered
                end
            end
        end
        return 200, { ["Content-Type"] = "text/plain; version=0.0.4" }, merge_metrics(texts)
    elseif path == "/stats" then
        return 200, { ["Content-Type"] = "application/json" }, moon.server_stats()
    end
    return 404, { ["Content-Type"] = "text/plain" }, "not found\n"
end

service.run({
    name = "admin",
    commands = {},
    on_start = function(self)
        -- Readiness: every required local service must be registered.
        for _, name in ipairs(self.config.required_services or {}) do
            health.register(name, function()
                return moon.query(name) ~= 0
            end)
        end

        local addr = self.config.addr or os.getenv("CCS_ADMIN_ADDR") or "0.0.0.0:9002"
        self.listen_fd = httpd.listen(addr)

        -- Register an async httpd handler so it can yield (aggregate metrics).
        moon.dispatch("httpd", function(_, _, req, handle)
            moon.async(function()
                local status, headers, body = handle_request(self, req)
                core.response(handle, status, headers, body)
            end)
        end)

        moon.info("admin listening on " .. addr)
    end,
    on_stop = function(self)
        if self.listen_fd then
            httpd.close(self.listen_fd)
            self.listen_fd = nil
        end
    end,
}, ...)

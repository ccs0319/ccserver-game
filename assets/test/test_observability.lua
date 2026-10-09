---
--- test_observability.lua — metrics / health / trace + admin HTTP endpoints.
--- Run:  moon_rs assets/test/test_observability.lua

local moon = require("moon")
local json = require("json")
local http = require("moon.http.client")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local metrics = require("ccserver.metrics")
local health = require("ccserver.health")
local trace = require("ccserver.trace")

local GATEWAY = "127.0.0.1:19111"
local ADMIN = "127.0.0.1:19112"

moon.loglevel("INFO")

local failed = 0
local function check(cond, msg)
    if cond then
        print("  PASS " .. msg)
    else
        failed = failed + 1
        print("  FAIL " .. msg)
    end
end

-- Direct module tests ------------------------------------------------------
metrics.reset()
metrics.counter("t_total", "test counter")
metrics.inc("t_total", 1, { a = "b" })
metrics.inc("t_total", 2, { a = "b" })
check(metrics.get("t_total", { a = "b" }) == 3, "counter increments")

metrics.set("t_gauge", 5)
check(metrics.get("t_gauge") == 5, "gauge set")

metrics.observe("t_hist", 0.05)
metrics.observe("t_hist", 0.5)
local text = metrics.render()
check(text:find('t_total{a="b"} 3', 1, true) ~= nil, "render counter line")
check(text:find("# TYPE t_hist histogram", 1, true) ~= nil
    and text:find('t_hist_bucket{le="%+Inf"} 2', 1, false) ~= nil, "render histogram buckets")

health.register("always_ok", function() return true end)
health.register("always_bad", function() return false, "nope" end)
local hok, hres = health.run()
check(hok == false and #hres == 2, "health.run detects failure")

local id = trace.start("trace-1")
check(id == "trace-1" and trace.current() == "trace-1", "trace current id")
trace.clear()

local cfg = topology.validate({
    cluster = { enabled = true, listen = false, discovery_url = "http://127.0.0.1:2379/cluster?node={}" },
    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = { addr = GATEWAY } },
        login   = { source = "ccserver.services.login",   unique = true },
        lobby   = { source = "ccserver.services.lobby",   unique = true },
        world   = { source = "ccserver.services.world",   unique = true },
        admin   = { source = "ccserver.services.admin",   unique = true, config = {
            addr = ADMIN,
            required_services = { "gateway", "login", "lobby", "world" },
        } },
    },
    nodes = { [1] = { services = { "gateway", "login", "lobby", "world", "admin" } } },
})

moon.timeout(20000, function()
    moon.error("observability test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== observability test ===")
    node.start(cfg, 1)
    moon.sleep(300)

    local h = http.get("http://" .. ADMIN .. "/health")
    check(h and h.status_code == 200 and h.body:find("ok") ~= nil, "GET /health")

    local r = http.get("http://" .. ADMIN .. "/ready")
    check(r and r.status_code == 200, "GET /ready -> 200")
    if r then
        local rj = json.decode(r.body)
        check(rj and rj.ok == true, "ready reports ok")
    end

    local m = http.get("http://" .. ADMIN .. "/metrics")
    check(m and m.status_code == 200 and m.body:find("ccserver_connections", 1, true) ~= nil,
        "GET /metrics aggregates gateway metrics")

    local s = http.get("http://" .. ADMIN .. "/stats")
    check(s and s.status_code == 200 and s.body:find("services", 1, true) ~= nil, "GET /stats")

    local nf = http.get("http://" .. ADMIN .. "/nope")
    check(nf and nf.status_code == 404, "unknown path -> 404")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

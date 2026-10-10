---
--- test_reliability.lua — rate limit, circuit breaker, secrets + gateway rate limit.
--- Run:  moon_rs assets/test/test_reliability.lua

local moon = require("moon")
local fs = require("fs")
local socket = require("moon.socket")
local buffer = require("buffer")
local node = require("ccserver.node")
local topology = require("ccserver.topology")
local protocol = require("ccserver.protocol")
local ratelimit = require("ccserver.ratelimit")
local breaker = require("ccserver.breaker")
local secrets = require("ccserver.secrets")

local MSG = protocol.MSG
local TYPE = protocol.TYPE
local ADDR = "127.0.0.1:19121"

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

-- Token bucket -------------------------------------------------------------
do
    local t = 1000
    check(ratelimit.allow("k", 10, 2, t) == true, "ratelimit allows within burst")
    check(ratelimit.allow("k", 10, 2, t) == true, "ratelimit allows second")
    check(ratelimit.allow("k", 10, 2, t) == false, "ratelimit denies when exhausted")
    check(ratelimit.allow("k", 10, 2, t + 0.5) == true, "ratelimit refills over time")
    ratelimit.reset("k")
    check(ratelimit.size() == 0, "ratelimit reset")
end

-- Circuit breaker ----------------------------------------------------------
do
    local key = "svc"
    for _ = 1, 5 do
        breaker.record_failure(key)
    end
    check(breaker.state(key) == "open", "breaker opens after threshold")
    check(breaker.allow(key) == false, "breaker fails fast while open")

    -- simulate cooldown elapsing
    local ok = breaker.call(key, function() return true end, { threshold = 5, cooldown = -1 })
    check(ok == true, "breaker half-opens after cooldown and closes on success")
    check(breaker.state(key) == "closed", "breaker closed after success")

    breaker.reset(key)
    local r1, r2 = breaker.call(key, function() return false, "down" end, { threshold = 1 })
    check(r1 == false and r2 == "down", "breaker.call surfaces handler failure")
end

-- Secrets ------------------------------------------------------------------
do
    local dir = "/tmp/ccs_secret_test"
    fs.mkdir(dir)
    io.writefile(dir .. "/pw", "s3cr3t\n")
    check(secrets.get("pw", { file = dir .. "/pw" }) == "s3cr3t", "secret from file")
    check(secrets.get("PATH", { env = "PATH" }) ~= nil, "secret from env")
    check(secrets.redact("abc") == "<redacted:3 chars>", "redact hides value")
    check(secrets.redact(nil) == "<unset>", "redact nil")
end

-- Gateway rate limit integration ------------------------------------------
local responses = {}
local closed = {}

socket.on("message", function(fd, buf)
    local msg = protocol.decode(buffer.unpack(buf, "Z"))
    if msg and msg.type == TYPE.RESPONSE then
        responses[msg.seq] = msg.args
    end
end)
socket.on("close", function(fd) closed[fd] = true end)

local cfg = topology.validate({
    cluster = { enabled = true, listen = false, discovery_url = "http://127.0.0.1:2379/cluster?node={}" },
    services = {
        gateway = { source = "ccserver.services.gateway", unique = true, config = {
            addr = ADDR,
            rate = { per_sec = 1, burst = 2 },
        } },
        login = { source = "ccserver.services.login", unique = true },
        lobby = { source = "ccserver.services.lobby", unique = true },
        world = { source = "ccserver.services.world", unique = true },
    },
    nodes = { [1] = { services = { "gateway", "login", "lobby", "world" } } },
})

moon.timeout(15000, function()
    moon.error("reliability test timed out")
    moon.exit(1)
end)

moon.async(function()
    print("=== reliability test ===")
    node.start(cfg, 1)

    local fd = assert(socket.connect(ADDR, 5000))
    socket.start_read_frame(fd)

    -- HELLO (consumes one token; burst 2 leaves 1).
    socket.write_frame(fd, protocol.encode(TYPE.REQUEST, MSG.HELLO, 1, protocol.VERSION))
    moon.sleep(80)

    -- Burst of 10 PINGs should be mostly rate-limited.
    for i = 1, 10 do
        socket.write_frame(fd, protocol.encode(TYPE.REQUEST, MSG.PING, 100 + i))
    end
    moon.sleep(150)

    local limited, ok_count = 0, 0
    for i = 1, 10 do
        local args = responses[100 + i]
        if args then
            if args[1] == false and args[2] == "rate limited" then
                limited = limited + 1
            else
                ok_count = ok_count + 1
            end
        end
    end
    check(limited >= 5, "gateway rate limits bursts (limited=" .. limited .. ", ok=" .. ok_count .. ")")

    -- After refill, a request succeeds again.
    moon.sleep(1500)
    responses[200] = nil
    socket.write_frame(fd, protocol.encode(TYPE.REQUEST, MSG.PING, 200))
    moon.sleep(150)
    check(responses[200] ~= nil and responses[200][1] == true, "request allowed after refill")

    print("=== result: " .. (failed == 0 and "ALL PASS" or (failed .. " FAILED")) .. " ===")
    moon.exit(failed == 0 and 0 or 1)
end)

moon.shutdown(function()
    node.stop()
end)

---
--- benchmark_gateway.lua — client-side load generator for a running ccserver.
---
--- Connects N clients to the gateway, performs HELLO/LOGIN/ENTER, then hammers
--- a command for a fixed duration, reporting throughput and latency percentiles.
---
--- Env:
---   CCS_BENCH_ADDR  gateway address        (default 127.0.0.1:9001)
---   CCS_BENCH_CONN  concurrent connections (default 100)
---   CCS_BENCH_SEC   duration seconds       (default 5)
---   CCS_BENCH_MSG   command: PING | MOVE   (default PING)
---
--- Run the server with a high rate limit (see scripts/bench.sh).

local moon = require("moon")
local socket = require("moon.socket")
local buffer = require("buffer")
local protocol = require("ccserver.protocol")

local MSG = protocol.MSG
local TYPE = protocol.TYPE

local ADDR = os.getenv("CCS_BENCH_ADDR") or "127.0.0.1:9001"
local CONNECTIONS = tonumber(os.getenv("CCS_BENCH_CONN")) or 100
local DURATION = tonumber(os.getenv("CCS_BENCH_SEC")) or 5
local COMMAND = os.getenv("CCS_BENCH_MSG") or "PING"

moon.loglevel("INFO")

local seq = 0
local pending = {}
local total = 0
local samples = {}

local function request(fd, msgid, ...)
    seq = seq + 1
    local myseq = seq
    pending[myseq] = coroutine.running()
    socket.write_frame(fd, protocol.encode(TYPE.REQUEST, msgid, myseq, ...))
    local r = table.pack(moon.wait())
    pending[myseq] = nil
    return table.unpack(r, 1, r.n)
end

socket.on("message", function(fd, buf)
    local msg = protocol.decode(buffer.unpack(buf, "Z"))
    if msg and msg.type == TYPE.RESPONSE then
        local co = pending[msg.seq]
        if co then
            moon.wakeup(co, table.unpack(msg.args, 1, msg.args.n))
        end
    end
end)

local function percentile(sorted, p)
    if #sorted == 0 then
        return 0
    end
    local idx = math.max(1, math.min(#sorted, math.ceil(p * #sorted)))
    return sorted[idx]
end

moon.async(function()
    print(string.format("benchmark: addr=%s conn=%d duration=%ds cmd=%s", ADDR, CONNECTIONS, DURATION, COMMAND))

    local conns = {}
    for _ = 1, CONNECTIONS do
        local fd = socket.connect(ADDR, 5000)
        if fd then
            socket.start_read_frame(fd)
            conns[#conns + 1] = fd
        end
    end
    print(string.format("connected: %d/%d", #conns, CONNECTIONS))
    if #conns == 0 then
        moon.exit(1)
    end

    -- Handshake every connection.
    for _, fd in ipairs(conns) do
        request(fd, MSG.HELLO, protocol.VERSION)
        local _, login = request(fd, MSG.LOGIN, "bench" .. fd, "pw")
        request(fd, MSG.ENTER, login.token)
    end

    local deadline = moon.clock() + DURATION
    local done = 0

    for _, fd in ipairs(conns) do
        moon.async(function()
            while moon.clock() < deadline do
                local t0 = moon.clock()
                local ok = request(fd, MSG[COMMAND])
                local dt = moon.clock() - t0
                if ok then
                    total = total + 1
                    samples[#samples + 1] = dt
                end
            end
            done = done + 1
        end)
    end

    while done < #conns do
        moon.sleep(5)
    end

    table.sort(samples)
    local elapsed = DURATION
    print("=== result ===")
    print(string.format("requests:   %d", total))
    print(string.format("throughput: %.0f req/s", total / elapsed))
    print(string.format("latency:    p50=%.3fms p90=%.3fms p99=%.3fms max=%.3fms",
        percentile(samples, 0.50) * 1000,
        percentile(samples, 0.90) * 1000,
        percentile(samples, 0.99) * 1000,
        (samples[#samples] or 0) * 1000))
    moon.exit(0)
end)

moon.shutdown(function()
    moon.quit()
end)

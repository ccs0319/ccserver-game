--- Prometheus-compatible metrics registry.
---
--- Counters, gauges and histograms with a text exposition renderer suitable for
--- a `/metrics` endpoint. Metrics are process-local (per actor); the admin
--- service exposes the ones registered in its own actor. Register/record from
--- any service with the same name to aggregate conceptually.
---
--- ```lua
--- local metrics = require("ccserver.metrics")
--- metrics.counter("ccserver_client_messages_total", "Client messages handled")
--- metrics.inc("ccserver_client_messages_total", 1, { msgid = "LOGIN" })
--- metrics.observe("ccserver_request_seconds", elapsed, { cmd = "MOVE" })
--- print(metrics.render())
--- ```

local M = {}

---@type table<string, {type:string, help:string, buckets:number[]?, series:table}>
local metrics = {}

local DEFAULT_BUCKETS = { 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 }

local function escape(v)
    return tostring(v):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function label_key(labels)
    if not labels or next(labels) == nil then
        return ""
    end
    local keys = {}
    for k in pairs(labels) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format('%s="%s"', k, escape(labels[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function declare(kind, name, help, buckets)
    if not metrics[name] then
        if kind == "histogram" and not buckets then
            buckets = DEFAULT_BUCKETS
        end
        metrics[name] = { type = kind, help = help or "", buckets = buckets, series = {} }
    end
    return metrics[name]
end

local function series_for(m, labels)
    local key = label_key(labels)
    local s = m.series[key]
    if not s then
        s = { labels = labels, value = 0, count = 0, sum = 0, buckets = {} }
        m.series[key] = s
    end
    return key, s
end

---@param name string
---@param help? string
function M.counter(name, help)
    declare("counter", name, help)
end

---@param name string
---@param help? string
function M.gauge(name, help)
    declare("gauge", name, help)
end

---@param name string
---@param help? string
---@param buckets? number[]
function M.histogram(name, help, buckets)
    declare("histogram", name, help, buckets or DEFAULT_BUCKETS)
end

---@param name string
---@param delta? number defaults to 1
---@param labels? table
function M.inc(name, delta, labels)
    local m = metrics[name] or declare("counter", name)
    local _, s = series_for(m, labels)
    s.value = s.value + (delta or 1)
end

---@param name string
---@param value number
---@param labels? table
function M.set(name, value, labels)
    local m = metrics[name] or declare("gauge", name)
    local _, s = series_for(m, labels)
    s.value = value
end

---@param name string
---@param value number
---@param labels? table
function M.observe(name, value, labels)
    local m = metrics[name] or declare("histogram", name)
    local _, s = series_for(m, labels)
    s.count = s.count + 1
    s.sum = s.sum + value
    for i, b in ipairs(m.buckets) do
        if value <= b then
            s.buckets[i] = (s.buckets[i] or 0) + 1
        end
    end
end

--- Read a series value (tests/debug).
---@param name string
---@param labels? table
---@return number|nil
function M.get(name, labels)
    local m = metrics[name]
    if not m then
        return nil
    end
    local s = m.series[label_key(labels)]
    return s and s.value or nil
end

local function le_key(labels, le)
    local merged = { le = le }
    for k, v in pairs(labels or {}) do
        merged[k] = v
    end
    return label_key(merged)
end

--- Render all metrics in Prometheus text exposition format.
---@return string
function M.render()
    local out = {}
    local names = {}
    for n in pairs(metrics) do
        names[#names + 1] = n
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local m = metrics[name]
        out[#out + 1] = "# HELP " .. name .. " " .. m.help
        out[#out + 1] = "# TYPE " .. name .. " " .. m.type

        local keys = {}
        for k in pairs(m.series) do
            keys[#keys + 1] = k
        end
        table.sort(keys)

        for _, k in ipairs(keys) do
            local s = m.series[k]
            if m.type == "histogram" then
                for i, b in ipairs(m.buckets) do
                    out[#out + 1] = string.format("%s_bucket%s %d", name, le_key(s.labels, b), s.buckets[i] or 0)
                end
                out[#out + 1] = string.format("%s_bucket%s %d", name, le_key(s.labels, "+Inf"), s.count)
                out[#out + 1] = string.format("%s_sum%s %g", name, k, s.sum)
                out[#out + 1] = string.format("%s_count%s %d", name, k, s.count)
            else
                out[#out + 1] = string.format("%s%s %g", name, k, s.value)
            end
        end
    end
    return table.concat(out, "\n") .. "\n"
end

--- Reset all metrics (tests).
function M.reset()
    metrics = {}
end

return M

# Observability (`ccserver`)

> Status: **M4 implemented.** Metrics, health/readiness probes and trace ids.

## Endpoints

The **admin** service exposes HTTP probes (config `services.admin.config.addr`,
env `CCS_ADMIN_ADDR`, default `0.0.0.0:9002`):

| Path | Meaning | Response |
| --- | --- | --- |
| `GET /health` | liveness (process is up) | `200 ok` |
| `GET /ready` | readiness (all checks pass) | `200`/`503` JSON `{ ok, checks }` |
| `GET /metrics` | Prometheus text (aggregated) | `200` `text/plain; version=0.0.4` |
| `GET /stats` | runtime stats | `200` JSON (`moon.server_stats()`) |

```bash
curl localhost:9002/ready
curl localhost:9002/metrics | head
```

## Metrics (`ccserver.metrics`)

Prometheus-compatible counters, gauges and histograms (per actor).

```lua
local metrics = require("ccserver.metrics")
metrics.counter("ccserver_client_messages_total", "Client messages handled")
metrics.inc("ccserver_client_messages_total", 1, { msgid = "LOGIN" })
metrics.gauge("ccserver_connections_active", "Open client connections")
metrics.set("ccserver_connections_active", n)
metrics.histogram("ccserver_client_request_seconds", "Latency")
metrics.observe("ccserver_client_request_seconds", elapsed, { msgid = "MOVE" })
metrics.render()   -- Prometheus text exposition
```

The gateway already records `ccserver_connections_total`,
`ccserver_connections_active`, `ccserver_client_messages_total{msgid}`,
`ccserver_errors_total`, `ccserver_client_request_seconds{msgid}`.

### Aggregation

Metrics are process-local (each actor owns its state). `/metrics` on the admin
**aggregates every local service** by RPC-ing its built-in `metrics` command and
merging the texts (first HELP/TYPE per name wins). Across nodes, the admin would
call remote services via the cluster.

## Built-in service commands

Every service answers these (user commands may override):

| Command | Returns |
| --- | --- |
| `metrics` | its Prometheus text |
| `info` | `{ name, node }` |
| `stats` | process runtime stats (`moon.server_stats()`) |

## Health / readiness (`ccserver.health`)

```lua
local health = require("ccserver.health")
health.register("db", function() return db.health("sql", "game") end)
local ok, results = health.run()   -- ok = all checks returned true
```

A check returns `ok, err`; a raised error counts as unhealthy. The admin
registers a check per `required_services` entry (service must be registered).

## Trace ids (`ccserver.trace`)

Coroutine-local ids for correlated logging:

```lua
local trace = require("ccserver.trace")
local id = trace.start()            -- or trace.start(client_seq)
moon.info("[" .. id .. "] handling request")
trace.clear()
```

The gateway assigns a trace id per client request and includes it in error logs.
Full distributed tracing (propagating the id across service calls) is a follow-up.

## Notes / follow-ups

- `/metrics` aggregation is a fan-out RPC; for many services, prefer pushing
  metrics to a process-global registry (native) or a Prometheus pushgateway.
- No OpenTelemetry/span export yet; trace ids are log-correlation only.
- `/stats` is process-wide; per-service detail is available via each service's
  `stats` command.

## Files

| Path | Role |
| --- | --- |
| `lualib/ccserver/metrics.lua` | metrics registry + Prometheus renderer |
| `lualib/ccserver/health.lua` | health check registry |
| `lualib/ccserver/trace.lua` | coroutine-local trace ids |
| `lualib/ccserver/services/admin.lua` | `/health` `/ready` `/metrics` `/stats` |
| `assets/test/test_observability.lua` | module + endpoint tests |

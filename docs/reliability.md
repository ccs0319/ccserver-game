# Reliability & Security (`ccserver`)

> Status: **M5 implemented.** Rate limiting, circuit breaker, graceful drain,
> secret isolation, and verified backups.

## Rate limiting (`ccserver.ratelimit`)

Token buckets keyed per connection / uid / command:

```lua
local ratelimit = require("ccserver.ratelimit")
if not ratelimit.allow("fd:" .. fd, 20, 40) then   -- 20/s, burst 40
    -- too fast
end
ratelimit.reset("fd:" .. fd)   -- on disconnect
```

The **gateway** applies a per-connection limit before dispatch
(`config.rate = { per_sec = 20, burst = 40 }`, or env `CCS_GATEWAY_RATE` /
`CCS_GATEWAY_BURST`). Over-limit requests get `ERROR "rate limited"` and are
counted in `ccserver_rate_limited_total`.

## Circuit breaker (`ccserver.breaker`)

Per-key (downstream service) state machine: after `threshold` consecutive
failures the breaker **opens** and fails fast for `cooldown` seconds, then
**half-opens** for a trial call.

```lua
local breaker = require("ccserver.breaker")
local ok, res = breaker.call("login", function()
    return router.call("login", "verify", token)
end, { threshold = 5, cooldown = 5 })
-- ok == false, "circuit open: login" while tripped
```

`state(key)` returns `closed | open | half_open`. Wrap latency-sensitive
downstream calls to avoid hammering a failing dependency.

## Graceful drain

On shutdown the gateway:

1. stops accepting new connections (listener closed, new accepts rejected),
2. waits `drain_grace_ms` (config, default 300ms) for in-flight requests,
3. closes remaining client connections.

`scripts/stop.sh` sends SIGTERM, which triggers the runtime shutdown and this
drain. Logs show `gateway draining (N active connections)`.

## Secret isolation (`ccserver.secrets`)

Secrets are never committed. Resolve at runtime, in order:

1. explicit env var (`opts.env`),
2. `CCS_SECRET_<KEY>` (upper-cased),
3. a file (`opts.file` or `opts.dir/<key>`).

```lua
local secrets = require("ccserver.secrets")
local pw = secrets.get("db_password", { dir = "/run/secrets" })
moon.info("pw = " .. secrets.redact(pw))   -- "<redacted:N chars>", never the value
```

The gateway already holds no auth secrets — it forwards credentials to `login`
and only handles the issued token.

## Backups: verified & scheduled

`scripts/backup.sh` writes a `MANIFEST` with each file's size and **sha256**.
Verify integrity any time:

```bash
scripts/backup.sh                 # create (make backup)
scripts/verify-backup.sh          # verify latest (make verify-backup)
scripts/verify-backup.sh 20260101_030000
```

`verify-backup.sh` reports missing/size/hash mismatches and exits non-zero, so
cron can alert on silent corruption:

```cron
0 * * * * cd /path/to/ccserver && scripts/backup.sh >> logs/backup.log 2>&1 && scripts/verify-backup.sh >> logs/backup.log 2>&1
```

See `docs/backup.md` for restore and production (PITR/replica) guidance.

## Files

| Path | Role |
| --- | --- |
| `lualib/ccserver/ratelimit.lua` | token-bucket limiter |
| `lualib/ccserver/breaker.lua` | circuit breaker |
| `lualib/ccserver/secrets.lua` | secret loading + redaction |
| `lualib/ccserver/services/gateway.lua` | per-conn rate limit + graceful drain |
| `scripts/verify-backup.sh` | backup integrity verification |
| `assets/test/test_reliability.lua` | limiter/breaker/secrets + gateway rate-limit tests |

## Follow-ups

- Per-uid (not just per-connection) limits and per-command quotas.
- Retry with jitter for idempotent reads; breaker metrics.
- Backups: automated restore-into-scratch verification; off-site copies.

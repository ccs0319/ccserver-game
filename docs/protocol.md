# Client Protocol & Sessions

> Status: **M2 implemented.** The gateway terminates client connections, enforces
> the wire protocol, manages sessions, and orchestrates backend services.

## Transport & framing

- Client ↔ gateway: TCP with the runtime's frame protocol
  (`socket.write_frame` / `start_read_frame`): `[2-byte BE length][body]`.
  Bodies larger than 65535 bytes are automatically chunked by the runtime.
- The **body** layout is defined by `ccserver.protocol`:

```
body    = [version:u8][type:u8][msgid:u16 BE][seq:u32 BE][payload...]
payload = seri.packstring(...)     -- binary codec (swap for protobuf later)
```

| Field | Meaning |
| --- | --- |
| `version` | protocol version (currently `1`) |
| `type` | `1` REQUEST, `2` RESPONSE, `3` NOTIFY |
| `msgid` | command id (see registry below); a RESPONSE echoes the request's msgid |
| `seq` | client-assigned request sequence; RESPONSE echoes it for correlation |
| `payload` | codec-encoded Lua values |

## Message registry

| id | name | direction | payload |
| --- | --- | --- | --- |
| 1 | HELLO | C→S | `client_version` |
| 2 | HELLO_ACK | S→C | `ok, server_version / err` |
| 10 | LOGIN | C→S | `account, password` |
| 11 | LOGIN_ACK | S→C | `ok, {uid, token} / err` |
| 12 | ENTER | C→S | `token` |
| 13 | ENTER_ACK | S→C | `ok, {uid, account, lobby, world} / err` |
| 14 | MOVE | C→S | `x, y` |
| 15 | MOVE_ACK | S→C | `ok, {x, y} / err` |
| 16 | PING | C→S | — |
| 17 | PONG | S→C | `ok, "pong"` |
| 99 | ERROR | S→C | `false, err` (protocol/handler error) |
| 100 | KICK | S→N | `reason` (server-initiated, 顶号) |

RESPONSE payloads are `(ok, data...)`; `ok == false` means `data` is an error
string. Add new ids at the end and keep them stable.

## Connection flow

```
client                         gateway                     backend
  │  HELLO(v)  ───────────────▶  version check
  │  ◀─────────── HELLO_ACK     (mismatch → ERROR + close)
  │  LOGIN(acc,pw) ───────────▶  router.call("login","login",…) ─▶ login
  │  ◀─────────── LOGIN_ACK {uid,token}
  │  ENTER(token) ────────────▶  router.call("login","verify",…)
  │                              ├─ kick old session for uid (顶号)
  │                              ├─ router.call("lobby","enter",uid)
  │                              └─ router.call("world","enter",uid,zone)
  │  ◀─────────── ENTER_ACK {uid,…}
  │  MOVE(x,y) ───────────────▶  router.call("world","move",uid,x,y)
  │  ◀─────────── MOVE_ACK
```

### Rules

- **Version negotiation first.** Any command before a successful HELLO is
  rejected with `hello required`. A version mismatch replies an error and closes
  the connection (explicit protocol evolution).
- **Sessions bind on ENTER**, not LOGIN: LOGIN authenticates and issues a token;
  ENTER verifies it and binds `fd → uid`.
- **顶号 (duplicate login).** When a uid binds on a new connection, the previous
  connection receives `KICK` and is closed. Only one active session per uid.
- **Reconnect.** Tokens are stateless (verified by `login`), so a client that
  reconnects and re-sends ENTER re-binds (kicking any stale session).
- **No secrets at the edge.** The gateway only forwards credentials to `login`
  and validates the returned token; it never stores passwords or signing keys.
- **Errors never hang.** Handler errors are caught and returned as
  `ERROR (false, err)`; unknown msgids likewise.

## Cross-gateway sessions (stateless gateways)

A gateway keeps its live connections locally, but **session ownership** lives in
a shared store (`ccserver.session`) so any gateway can see who owns a uid:

| Backend | Use |
| --- | --- |
| `session.memory()` | per-actor, single-gateway dev (default) |
| `session.redis(conn)` | shared, production (Redis + TTL) |

Gateway config `session = { redis_url = "redis://…", prefix, ttl }` enables the
Redis backend (falls back to memory if Redis is unreachable).

On ENTER the gateway:

1. reads `session:<uid>`; if another gateway owns it, asks that gateway to kick
   (`router.call(prev.gateway, "kick", uid)` — local or cross-node via cluster);
2. writes `session:<uid> = { gateway, node, zone, ts }`;
3. kicks its own previous local session for the uid (顶号).

On disconnect it removes the record only if it still owns it. This makes
**顶号 work across gateways/processes** and lets clients reconnect to any
gateway (tokens are stateless; just re-ENTER). Verified by
`assets/test/test_session.lua`.

> Note: the native Redis pool is process-global keyed by connection name, so each
> gateway uses a distinct name (`gw_session_<gateway>`); reusing a name in another
> actor would shut down the previous pool.

## Gateway configuration

Set in the topology (`services.gateway.config.addr`) or via env
`CCS_GATEWAY_ADDR`:

```lua
gateway = { source = "ccserver.services.gateway", unique = true,
            config = { addr = "0.0.0.0:9001" } },
```

## Testing

`assets/test/test_gateway.lua` boots a node and drives it as a real TCP client:
HELLO negotiation, LOGIN, ENTER (session bind), MOVE, PING, version-mismatch
rejection, and 顶号. Run via `make test-lua`.

## Files

| Path | Role |
| --- | --- |
| `lualib/ccserver/protocol.lua` | wire codec + message registry |
| `lualib/ccserver/services/gateway.lua` | client listener, dispatch, sessions, 顶号 |
| `lualib/ccserver/services/login.lua` | auth + token issuance/verification |
| `assets/test/test_gateway.lua` | protocol/session integration test |

## Not yet done (M2 follow-ups)

- Payload codec is `seri`; protobuf integration is planned.
- No encryption/compression; add at the frame layer when needed.
- Heartbeat timeout enforcement (PING exists; idle reaping is not wired yet).
- Rate limiting / backpressure (M5).

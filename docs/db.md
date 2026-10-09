# Database Layer (`moon.db`)

ccserver ships a **thin unified manager** over the native database drivers. The
recommended production stack is:

| Role | Driver | Cargo feature | Default |
| --- | --- | --- | --- |
| Cache / session / ranking | `moon.db.redis` (native Redis pool) | `redis` | **on** |
| Relational (MySQL / PostgreSQL / SQLite) | `moon.db.sqlx` (SQLx) | `sqlx` | **on** |
| Document store | `moon.db.mongodb` | `mongodb` | off |
| High-performance PostgreSQL wire driver | `moon.db.pg` | `pg` | off |

> Rationale: **SQLx is the single relational API**. It covers MySQL, PostgreSQL
> and SQLite through one Lua surface, so most projects never need the hand-written
> `pg` driver. `lua_pg` is retained as an optional, dependency-free
> high-performance alternative for PostgreSQL-only, latency-sensitive paths.

## Quick start

```lua
local moon = require("moon")
local db   = require("moon.db")

moon.async(function()
    db.setup {
        redis = {
            { name = "cache", url = "redis://127.0.0.1:6379/0?pool_size=2" },
        },
        sql = {
            { name = "game", url = "mysql://user:pass@127.0.0.1:3306/game",
              max_connections = 8, timeout = 5000 },
            { name = "stat", url = "postgres://user:pass@127.0.0.1:5432/stat" },
        },
        -- mongo = { { name = "log", url = "mongodb://127.0.0.1:27017" } },
    }

    local cache = db.redis("cache")   -- moon.db.redis connection
    local game  = db.sql("game")      -- moon.db.sqlx connection

    local rows = game:query("SELECT uid, name FROM player WHERE level > ?", 10)
    cache:set("online:1", "1")
    cache:zadd("rank", 250, "Bob")

    db.close_all()
end)
```

`moon.db.setup` opens every declared connection (async), registers it by `name`,
and `db.redis(name)` / `db.sql(name)` / `db.mongo(name)` return the handle.
Call `db.close_all()` on shutdown.

See `assets/example/example_db.lua` for a runnable example (SQLite in-memory +
optional Redis).

## Config reference

Each entry requires `name` and `url`; optional pool knobs depend on the driver.

| Kind | Fields | Notes |
| --- | --- | --- |
| `redis` | `name`, `url` | Pool params live in the URL (`pool_size`, `connect_timeout`, `queue_capacity`). `name` is appended to the URL automatically. |
| `sql` | `name`, `url`, `timeout`, `max_connections`, `queue_capacity` | URL prefix selects the backend: `mysql://`, `postgres://` / `postgresql://`, `sqlite::memory:` (in-memory) or `sqlite:///abs/path.db` (file). |
| `mongo` | `name`, `url`, `queue_capacity` | Requires `--features mongodb`. |

### Placeholders

Bind parameters are positional and backend-specific (passed verbatim to `sqlx`):

- MySQL / SQLite: `?`
- PostgreSQL: `$1`, `$2`, ...

```lua
-- MySQL / SQLite
db.sql("game"):query("SELECT * FROM player WHERE uid = ?", 1)
-- PostgreSQL
db.sql("stat"):query("SELECT * FROM player WHERE uid = $1", 1)
```

## Driver details

- **Redis** — full command surface via dynamic dispatch (`cache:get(...)`,
  `cache:zrevrange(...)`, ...), pipelining (`:pipeline` / `:execute_pipeline`),
  pub/sub (`redis.watch(url)`). Use sorted sets for leaderboards.
- **SQLx** — `:query` / `:execute` / `:transaction` / `:query_stream`, plus
  `sqlx.json(...)` for explicit JSON parameters. Result is an array of row tables;
  errors are `{ kind = ..., message = ... }`.
- **MongoDB** — collection API + streaming cursor. Feature-gated.
- **pg** (optional) — wire-protocol driver with `query_params`, `pipe`,
  `insert_many`, `update_many`, SCRAM-SHA-256 auth. See `docs/pg.md`.

## Health, stats & backend detection

```lua
db.health("sql", "game")      -- SELECT 1 probe -> true | false, err
db.health("redis", "cache")   -- PING        -> true | false, err
db.health_all()               -- [ { kind, name, ok, err }, ... ]
db.stats()                    -- { redis=..., sql=..., mongo=... } pool stats
db.sql_backend("game")        -- "mysql" | "postgres" | "sqlite"
```

`sql_backend` is derived from the URL scheme and is used by the migration runner to
pick the right advisory lock.

## Schema migrations

`moon.db.migration` applies ordered files and records version + name + **checksum**:

```lua
local migration = require("moon.db.migration")
local backend = db.sql_backend("game")            -- "mysql" | "postgres" | "sqlite"

migration.run(db.sql("game"), "migrations", { backend = backend })
migration.verify(db.sql("game"), "migrations")     -- detect edits to applied files
migration.rollback(db.sql("game"), "migrations", 1, { backend = backend })
migration.status(db.sql("game"))
```

- Files: `NNNN_name.lua` returning a list of up statements, or
  `{ up = {...}, down = {...} }` for rollback.
- `run` takes a backend **advisory lock** (MySQL `GET_LOCK`, PostgreSQL
  `pg_advisory_lock`) so concurrent nodes cannot double-apply.
- `verify` compares recorded checksums to the files, catching silent edits.
- See `assets/migration/` for examples and `assets/test/test_migration.lua`.

## Building

```bash
# Default build: redis + sqlx (MySQL/PostgreSQL/SQLite)
cargo build --release

# Add MongoDB and/or the optional high-performance pg driver
cargo build --release --features mongodb,pg
```

## `namesearch`

`lualib/moon/namesearch.lua` (prefix / substring / fuzzy player-name search) is
built on **SQLx and requires a PostgreSQL backend** — the indexes use
`text_pattern_ops` and `pg_trgm` (`gin_trgm_ops`).

## Files

| Path | Role |
| --- | --- |
| `lualib/moon/db.lua` | unified connection manager (this doc) |
| `lualib/moon/db/redis.lua` | Redis driver wrapper |
| `lualib/moon/db/sqlx.lua` | SQLx driver wrapper |
| `lualib/moon/db/mongodb.lua` | MongoDB driver wrapper |
| `lualib/moon/db/pg.lua` | optional pg driver wrapper |
| `crates/moon-runtime/src/modules/lua_{redis,sqlx,mongodb,pg}.rs` | Rust implementations |

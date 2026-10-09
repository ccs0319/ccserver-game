# Configuration (`moon.config`)

Layered configuration with schema validation and validated hot reload.

## Loading

```lua
local config = require("moon.config")

-- single file (.lua returning a table, or .json)
local cfg = config.load("config/server.lua")

-- layered: later files deep-merge over earlier ones
local cfg = config.load_layered({ "config/base.lua", "config/dev.lua", "config/local.lua" })
```

`merge(base, override)` recurses into tables: nested keys are merged, scalars from
`override` win.

## Schema validation

`validate(cfg, schema)` checks required fields and types. `schema` maps a key to an
expected type (`"string" | "number" | "integer" | "boolean" | "table"`) or to a
nested schema table. It raises with the offending dotted path.

```lua
config.validate(cfg, {
    port = "integer",
    loglevel = "string",
    db = {
        redis = "table",
        sql   = "table",
    },
})
-- config: field `db.redis` expected table, got nil
```

## Validated hot reload

`watch(path, interval_ms, on_change, { schema = ... })` polls the file and applies
changes. With a schema, an invalid update is **logged and rejected** — the
previous value is kept and `on_change` is not called.

```lua
local handle = config.watch("config/server.lua", 2000, function(new, old)
    apply(new, old)
end, {
    schema = { port = "integer" },
})

handle:get()   -- current value
handle:stop()  -- stop polling
```

## Notes

- `.lua` config files are loaded via `load(io.readfile(path), "@"..path)` (the
  runtime's `loadfile` returns stale content for rewritten files).
- Hot reload is **content-diff based polling** for now; an event-driven watcher
  (Rust `notify`) and cross-service broadcast are planned (see `docs/architecture.md`).
- Secrets should not be committed; load them from env/secret files and merge them
  at runtime (they then never appear in config files under version control).

## Files

| Path | Role |
| --- | --- |
| `lualib/moon/config.lua` | load / merge / validate / layered / watch |
| `assets/test/test_config.lua` | merge, validation, layered, validated reload tests |

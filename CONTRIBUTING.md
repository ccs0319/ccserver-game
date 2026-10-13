# Contributing to ccserver

Thanks for contributing! ccserver is a game-server framework built on
[`moon_rs`](https://github.com/sniper00/moon_rs) (Rust + Lua actor runtime).
**Read [`AGENTS.md`](AGENTS.md) first** — it is the authoritative guide, and
`docs/agent/` holds the living state/decisions.

## Prerequisites

- Rust **stable** (pinned by `rust-toolchain.toml`; 1.96+).
- Docker (optional) for local dependencies: `make db-up`.
- `gh` (optional) for PRs.

## Build, test, run

```bash
make build          # cargo build --release
make check          # cargo check --workspace
make test           # cargo test
make test-lua       # Lua integration tests (no external services)
make test-db        # db + migration tests (needs make db-up)
make lint           # fmt + clippy + agent-check
make run            # foreground (BOOTSTRAP=app/main.lua)
make start / stop   # background (pidfile + logs)
make bench          # gateway load test
make smoke          # end-to-end smoke
```

Full cluster:

```bash
make test-multinode        # 2-node cluster (static HTTP registry)
make test-multinode-etcd   # 2-node cluster (etcd discovery)
```

## Development workflow

1. Read `AGENTS.md` §0 and `docs/agent/{STATE,TODO,DECISIONS}.md`.
2. Make a focused change; prefer **new crates / new Lua files** over editing
   upstream `moon_rs` files (see `AGENTS.md` §1.1).
3. Add/extend tests (`assets/test/`) and docs (`docs/`).
4. Update the memory layer (per `AGENTS.md` §0.2): `STATE.md`, `TODO.md`,
   `DECISIONS.md` (ADR), and the `AGENTS.md` changelog.
5. Run `make lint` (fmt + clippy + `cargo xtask agent-check`).
6. Commit.

## Conventions

- **Rust**: edition 2024; crates `moon-*`; Lua bindings `lua_<feature>.rs`;
  feature-gate new modules. See `AGENTS.md` §5–§6.
- **Lua**: native modules `*.core`; wrappers under `lualib/`; framework layer in
  `lualib/ccserver/`; reference app in `app/`. Don't add comments unless they
  explain non-obvious intent.
- **Services**: implement via `ccserver.service`; route by logical name with
  `ccserver.router` (local-first). Handlers are `function(self, seq, ...)` for
  gateway client commands.
- **Upstream sync**: keep our delta minimal; sync with
  `scripts/update-upstream.sh` (fetch + rebase).

## Commit style

`<type>(<scope>): <summary>`, type ∈ `feat|fix|docs|refactor|test|chore|perf|build|ci`.
One concern per commit. Reference the milestone (e.g. `feat(m2): ...`).

## Pull requests

- Branch from `main`; keep PRs focused.
- Ensure CI is green (`.github/workflows/ci.yml`: fmt, clippy, test, build,
  Lua integration tests, db tests).
- Describe the change, the tests run, and any memory-layer updates.

## Where things live

| Area | Path |
| --- | --- |
| Framework (services/router/topology/protocol/observability) | `lualib/ccserver/` |
| Reference app (entry + topology) | `app/` |
| Data layer | `lualib/moon/db*`, `lualib/moon/config.lua` |
| Ops scripts | `scripts/`, `Makefile`, `docker-compose.yml` |
| Docs | `docs/`, `docs/agent/` |
| Tests | `assets/test/`, `assets/benchmark/` |

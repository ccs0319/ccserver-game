# Load Testing & Capacity

> Status: **M6 implemented.** CI (`.github/workflows/ci.yml`) + gateway load
> generator + a single-node baseline. Numbers below are **indicative**, measured
> on a dev machine with client and server sharing one host.

## Running

```bash
# one-shot: start server (rate limit disabled), load test, stop
CONN=100 SEC=5 MSG=PING make bench
# or directly:
scripts/bench.sh
```

Env: `CONN` (connections, default 100), `SEC` (duration, default 5),
`MSG` (`PING` | `MOVE`), `CCS_BENCH_ADDR`.

The generator (`assets/benchmark/benchmark_gateway.lua`) connects N clients,
performs HELLO/LOGIN/ENTER on each, then hammers the command for the duration and
reports throughput and latency percentiles.

> The server must run with a high rate limit for benchmarking; `scripts/bench.sh`
> sets `CCS_GATEWAY_RATE`/`CCS_GATEWAY_BURST` high.

## Baseline (dev machine, loopback, single node)

| Command | Conn | Throughput | p50 | p90 | p99 |
| --- | --- | --- | --- | --- | --- |
| `PING` (edge only) | 100 | ~174k req/s | 0.57 ms | 0.70 ms | 0.87 ms |
| `MOVE` (→ world service) | 100 | ~128k req/s | 0.77 ms | 0.94 ms | 1.14 ms |
| `PING` | 500 | ~171k req/s | 2.91 ms | 3.37 ms | 4.14 ms |

**How to read this.** `PING` measures the gateway edge path (framing + dispatch +
reply); `MOVE` adds one service round-trip through the router to `world`. These
are framework-overhead numbers, not gameplay throughput.

## Caveats

- **Shared host**: the load generator and the server run on the same machine and
  compete for CPU, so these are lower bounds for a dedicated server.
- **Cheap commands**: real gameplay handlers do more work than `PING`/`MOVE`.
- **Single node**: one process; multi-node/sharding changes the picture.
- **Not a guarantee**: use these to size the box and shard count, then re-measure
  with your real protocol and handlers.

## Scaling to N players

See `docs/architecture.md`. For thousands of concurrent players: horizontally
scale gateways (connections are cheap), **shard the world** (`world_1..N`, one
actor per zone/line), keep login/lobby stateless, and use Redis/DB for hot state.
The single-actor world is the throughput ceiling per shard — measure per-shard
capacity, then add shards.

## CI

`.github/workflows/ci.yml` runs on push/PR:

| Job | What |
| --- | --- |
| `lint` | `cargo fmt --check`, `cargo clippy --workspace --all-targets` |
| `test` | `cargo xtask agent-check`, `cargo test --workspace` |
| `build` | `cargo build --release -p moon-app` |
| `lua-tests` | Lua integration tests needing no external services |
| `db-tests` | `test_db_stack` + `test_migration` with Redis/MySQL/PostgreSQL services |

## Files

| Path | Role |
| --- | --- |
| `assets/benchmark/benchmark_gateway.lua` | load generator |
| `scripts/bench.sh` | one-shot bench (start server + load + stop) |
| `.github/workflows/ci.yml` | CI pipeline |

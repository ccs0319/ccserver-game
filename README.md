# ccserver

**ccserver** 是一个基于 [`moon_rs`](https://github.com/sniper00/moon_rs) 改造的**游戏服务器框架**。
它继承了 moon_rs 的 **Lua Actor 运行时（Tokio 驱动）**，并在此基础上沉淀可复用的游戏服务域层：
网关 / 会话、世界与场景、房间、AOI、协议编解码、配置表、分布式集群等。

> 上游关系：本项目 fork 改造自 [`sniper00/moon_rs`](https://github.com/sniper00/moon_rs)
> （基线 commit `272c9b8`），并继承其上游 [`sniper00/moon`](https://github.com/sniper00/moon)
> 的设计。MIT 许可与原创署名见 [`LICENSE`](./LICENSE)。

## 为什么是它

- **Lua-first Actor 模型**：service 之间通过类型化消息通信，游戏逻辑用 Lua 编写。
- **Tokio 驱动的运行时**：网络、定时器、HTTP、数据库 I/O 与并发由 Rust 承担。
- **单 actor 隔离**：每个 actor 拥有独立 `lua_State`，支持普通 actor 与独占线程的 unique actor。
- **实用的原生模块**：HTTP 客户端/服务端、WebSocket、Redis、PostgreSQL、SQLx、MongoDB、
  cluster、文件系统、JSON、buffer、随机数、Excel/CSV 等。
- **特性门控**：可选模块通过 Cargo feature 编译进/出。

## 工作区结构

| 路径 | 职责 |
| --- | --- |
| `crates/moon-app` | 二进制入口 `moon_rs`：bootstrap、信号处理 |
| `crates/moon-runtime` | Actor 运行时 + 全部 Rust→Lua 原生绑定 |
| `crates/moon-base` | 基础层：内嵌 Lua 5.5、Rust FFI、宏、共享 Buffer |
| `crates/moon-game` | 纯 Rust 玩法算法（AOI、math 等，无 Lua/FFI 依赖） |
| `lualib/` | 面向用户的 Lua API 与封装 |
| `assets/` | 示例、benchmark、Lua 集成测试脚本 |
| `docs/` | 模块文档；`docs/agent/` 为 agent 记忆层 |

## 数据库支持

推荐组合（见 [`docs/db.md`](docs/db.md)）：**Redis + SQLx + 可选 MongoDB**，通过统一的
`moon.db` 管理器配置与打开：

```lua
local db = require("moon.db")
db.setup {
    redis = { { name = "cache", url = "redis://127.0.0.1:6379/0?pool_size=2" } },
    sql   = { { name = "game",  url = "mysql://user:pass@127.0.0.1:3306/game" } },
    -- mongo = { ... }  -- 需要 --features mongodb
}
local rows = db.sql("game"):query("SELECT uid, name FROM player WHERE level > ?", 10)
db.redis("cache"):zadd("rank", 250, "Bob")
```

| 角色 | 驱动 | feature | 默认 |
| --- | --- | --- | --- |
| 缓存 / session / 排行 | `moon.db.redis` | `redis` | 开 |
| 关系型（MySQL / PostgreSQL / SQLite） | `moon.db.sqlx` | `sqlx` | 开 |
| 文档存储 | `moon.db.mongodb` | `mongodb` | 关 |
| 高性能手写 PostgreSQL 驱动 | `moon.db.pg` | `pg` | 关 |

## 快速开始

工具链由 `rust-toolchain.toml` 固定为 **stable**（本地验证 1.96.0）。

```bash
cargo build --release
cargo run --release -- assets/example/example.lua
cargo run --release -- assets/example/example_httpd.lua

cargo check --workspace          # 快速类型检查
cargo test                       # Rust 单元测试
cargo xtask agent-check          # 校验 AGENTS.md / docs/agent 记忆层
```

## 文档

- 开发指南（**唯一权威、自更新**）：[`AGENTS.md`](./AGENTS.md)
- 当前状态：`docs/agent/STATE.md` · 任务队列：`docs/agent/TODO.md` · 决策记录：`docs/agent/DECISIONS.md`
- 数据库层：[`docs/db.md`](docs/db.md)；配置：[`docs/config.md`](docs/config.md)；备份/恢复：[`docs/backup.md`](docs/backup.md)
- 架构与服务拓扑：[`docs/architecture.md`](docs/architecture.md)；协议与会话：[`docs/protocol.md`](docs/protocol.md)
- 可观测性：[`docs/observability.md`](docs/observability.md)；可靠性：[`docs/reliability.md`](docs/reliability.md)；压测：[`docs/benchmark.md`](docs/benchmark.md)
- 模块文档：`docs/socket.md`、`docs/httpc.md`、`docs/httpd.md`、`docs/redis.md`、`docs/pg.md`、
  `docs/sqlx.md`、`docs/mongodb.md`、`docs/cluster.md`、`docs/grpc.md` 等。

## License

MIT。见 [`LICENSE`](./LICENSE)。本项目保留对上游 moon_rs / Moon 的署名。

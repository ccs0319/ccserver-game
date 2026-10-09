# AGENTS.md — ccserver 开发指南（自更新）

<!-- agent-meta
version: 0.5.0
status: bootstrap
last_updated: 2026-10-09
upstream_repo: https://github.com/sniper00/moon_rs
upstream_baseline: 272c9b8f035decd60bf3cb4e4930c75eb0f47217
upstream_sync: rebase our delta onto upstream/main (scripts/update-upstream.sh)
repo: https://github.com/ccs0319/ccserver-game
-->

> 本文件是 **ccserver** 项目对 AI 编码代理（agent）的唯一权威指南。
> 它被设计为 **自更新（self-updating）**：每轮开发结束时，代理必须按 §0 的协议回写本文件
> 与 `docs/agent/` 记忆层。任何与本文件冲突的旧文档，以本文件为准。

---

## §0 自更新协议（MUST READ — 每个 agent 必读）

你是接手 ccserver 的编码代理。**在开始任何改动之前**，先按顺序读完：

1. 本文件 `AGENTS.md`（当前页）。
2. `docs/agent/STATE.md` —— 项目此刻的真实进度、进行中任务、已知坑。
3. `docs/agent/TODO.md` —— 待办任务队列。
4. `docs/agent/DECISIONS.md` —— 历史架构决策（ADR），不要推翻未标废弃的决策。

### §0.1 何时必须更新（触发条件）

只要发生以下任一情况，就 **必须** 在当轮结束前更新记忆层：

- 完成 / 部分完成 `docs/agent/TODO.md` 中的一项任务；
- 新增、删除或重命名了 crate / 模块 / Lua API；
- 更改了构建、测试、运行命令或依赖；
- 踩到坑、发现上游基线的行为陷阱、或推翻了某个假设；
- 做出了影响后续开发的架构决策；
- 升级了上游 `moon_rs` 基线（记录新的 commit sha）。

### §0.2 更新什么（写哪里）

| 文件 | 更新内容 |
| --- | --- |
| `docs/agent/STATE.md` | 最新进度、`last_updated`、进行中任务、阻塞项、已知坑 |
| `docs/agent/TODO.md` | 勾选完成项、拆分新增项、调整优先级 |
| `docs/agent/DECISIONS.md` | 追加一条 `ADR-NNN`（决策 + 理由 + 日期 + 状态） |
| `AGENTS.md` | 更新 meta 块的 `version`/`last_updated`，必要时改结构/约定，并在 §11 追加一行变更日志 |

### §0.3 更新纪律

- 时间戳使用 `YYYY-MM-DD`；`last_updated` 必须是当轮真实日期。
- 记忆层只写 **事实与决策**，不写空话；每条进度要能对应到代码或提交。
- **不要** 删除历史 ADR；要改就用新 ADR 标注 `Supersedes: ADR-NNN`。
- **不要** 让 `AGENTS.md` 与本文件描述的能力“漂移”：改了命令/结构，同一轮同步。
- 提交前运行 `cargo xtask agent-check`（§4），它会校验记忆层格式是否合格。

### §0.4 每轮收尾检查清单

- [ ] 代码可编译：`cargo check --workspace`（必要时 `cargo test`）。
- [ ] 已按 §0.2 回写记忆层与 meta。
- [ ] `cargo xtask agent-check` 通过。
- [ ] 提交信息遵循 §10 约定。

---

## §1 项目定位

**ccserver** 是一个 **基于 [`moon_rs`](https://github.com/sniper00/moon_rs) 改造的游戏服务器框架**。
它继承 moon_rs 的能力——**Lua 脚本化的 Actor 运行时（Tokio 驱动）**——并在此之上沉淀一套
**可复用的游戏服务域层**：网关 / 会话、世界与场景、房间、AOI、协议编解码、配置表、分布式集群等。

- 上游关系：**fork 改造**，保留 MIT 许可与上游署名（见 `LICENSE`、`README.md`）。
- 语言与运行时：Rust（框架与 I/O）+ Lua（游戏逻辑脚本）。
- 目标：让开发者用 Lua 写游戏逻辑，用 Rust 拿性能与并发。

### §1.1 与上游同步（重要）

本仓库历史 **以上游基线 commit 为根**，我们的改动是叠在其上的薄 delta。同步上游：

```bash
scripts/update-upstream.sh          # git fetch upstream + git rebase upstream/main
```

- **尽量不改上游文件**：新增能力优先放在新 crate / 新 Lua 文件，减少 rebase 冲突。
- 必须改上游文件时：改动要小、要聚焦，并在 `DECISIONS.md` 记一条 ADR；能上游化的 bug 优先提 PR。
- 每次同步后：更新 `AGENTS.md` 的 `upstream_baseline` 与 `docs/agent/STATE.md` 的「上游基线」，并跑 `cargo xtask agent-check`。
- 已知本地对上游的改动（保持最小）：`crates/moon-runtime/Cargo.toml`（默认 feature 调整）、
  `crates/moon-runtime/src/modules/lua_sqlx.rs`（SQLite 前缀判断，支持 `sqlite::memory:`）。

---

## §2 硬性规则（不得违反）

1. **保留署名**：不得移除 `LICENSE` 与 README 中对上游 moon_rs / Moon 的署名。
2. **不破坏既有 API**：修改 `lualib/` 用户态 API 或 `PTYPE_*` 协议常量前，先查 `DECISIONS.md`。
3. **Lua FFI 安全**：改动 Lua C API 互操作时，递归调用前必须 `lua_checkstack`；错误返回用
   `lua_push_error()`（`(false, errmsg)`），硬错误用 `laux::lua_error()`。
4. **特性门控**：新原生模块必须用 `#[cfg(feature = "...")]` 门控，并在 `moon-runtime/Cargo.toml` 注册 feature。
5. **无注释噪音**：除非被要求，不要给代码加解释性注释；让命名与结构自解释。
6. **先读后写**：改任何文件前先读它及其相邻文件，遵循既有风格与依赖选择。
7. **不擅自提交/推送**：仅在用户明确要求时 `git commit` / `git push`。

---

## §3 工作区结构

```
crates/
  moon-base/      # 基础层：内嵌 Lua 5.5 C 源码 + Rust FFI(laux)、宏、共享 Buffer、yyjson JSON
  moon-runtime/   # Actor 运行时（CONTEXT/消息/定时器/日志）+ 全部 Rust→Lua 原生绑定(lua_*.rs)
  moon-app/       # 二进制入口 moon_rs：Tokio 初始化、bootstrap、信号处理
  moon-game/      # 纯 Rust 玩法算法（无 Lua/FFI）：AOI、math、后续寻路/空间查询等
  xtask/          # 工作区任务运行器（cargo xtask ...）
lualib/           # 面向用户的 Lua API 与封装（moon.lua、socket、http、db 等）
  moon/db.lua     # 统一数据库连接管理器（Redis + SQLx + 可选 Mongo）
  moon/db/*.lua   # 各驱动封装 + migration.lua（结构迁移）
  moon/config.lua # 配置加载 + 热重载
  moon/hotreload.lua # 基于 hotfix 的代码热更
  ccserver/       # 游戏服务器框架层：service.lua/router.lua/topology.lua/node.lua/protocol.lua + services/
app/              # 参考应用：main.lua（入口）+ config/topology.lua（服务拓扑）
assets/           # 示例、benchmark、Lua 集成测试脚本；assets/migration/ 迁移示例
scripts/          # 一键启停 / 依赖拉起 / 上游同步脚本
docker-compose.yml# 本地依赖：Redis / MySQL / PostgreSQL / MongoDB
Makefile          # 开发任务入口（make help）
docs/             # 模块文档；docs/agent/ 为 agent 记忆层
```

---

## §4 构建 / 测试 / 运行

> 工具链由 `rust-toolchain.toml` 固定为 **stable**（含 rustfmt/clippy）。本地已在
> stable 1.96.0 上验证 `cargo check --workspace` 通过。上游 README 所说的 “nightly” 已过时。

```bash
cargo build --release                      # 构建
cargo check --workspace                    # 快速类型检查（agent 每轮收尾必跑）
cargo test                                 # Rust 单元测试
cargo run --release -- assets/example/example.lua   # 跑示例
cargo run --release -- assets/example/example_httpd.lua

cargo xtask agent-check                    # 校验 AGENTS.md / docs/agent 记忆层格式
cargo xtask list                           # 列出 Lua C 扩展与锁定状态

# 一键运维（见 Makefile / scripts/）
make db-up                                 # 起本地 Redis/MySQL/PostgreSQL/Mongo（docker compose）
make run                                   # 前台运行 example_server.lua
make start / stop / restart / status       # 后台运行（pidfile + logs/）
make backup / restore                      # 数据库备份 / 恢复（scripts/backup.sh、restore.sh）
scripts/update-upstream.sh                 # 同步上游 moon_rs（fetch + rebase）
```

- 默认 feature 较全（`excel,httpc,httpd,websocket,pg,redis,cluster,protobuf,sqlx,mongodb,grpc`）。
  裁剪可用 `--no-default-features --features ...`。
- 上游 CI 只做 release 构建（`.github/workflows/build.yml`）；本仓库应补充 fmt/clippy/test。

---

## §5 代码约定

### Rust
- Edition **2024**；crate 命名 `moon-*`，Lua 绑定文件命名 `lua_<feature>.rs`。
- 分配器 `mimalloc`（在 `moon-app` 设置）；异步运行时 Tokio 多线程 + `CONTEXT` 内专用 IO runtime。
- 错误处理：`moon_runtime::Error` + `derive_more::From`。
- 大量 `unsafe` 是 Lua C API 互操作的必然；包装函数用 `not_null_wrapper!` 生成 `extern "C-unwind"`。
- 全局单例：`CONTEXT`（actor 注册表/运行时）、`LOGGER`，均 `lazy_static`。

### Lua
- 原生模块注册名：`moon.core`、`net.core`、`httpc.core`、`httpd.core` …
- 分层：C core → `lualib/moon/*.lua` 封装 → 用户脚本。
- IDE 注解（EmmyLua）放在 `lualib/moon/api/*.lua`。

---

## §6 新增原生模块的标准流程

1. 新建 `crates/moon-runtime/src/modules/lua_<name>.rs`。
2. 若依赖可选 crate，在 `crates/moon-runtime/Cargo.toml` 加 feature。
3. 在 `crates/moon-runtime/src/lib.rs` 用 `lua_require!` 注册（带 `#[cfg(feature)]`）。
4. 新建 Lua 封装 `lualib/moon/<name>.lua`。
5. 补测试与 `docs/<name>.md`，并按 §0 更新记忆层。

---

## §7 架构要点

- **进程模型**：**单进程、多线程**。一个 `moon_rs` 二进制 = 一个 OS 进程；Tokio 多线程运行时
  + `unique` actor 各自独占 OS 线程。跨进程/多节点用 `cluster` 模块（每个节点是独立进程）。
- **服务拓扑**：框架层在 `lualib/ccserver/`（service/router/topology/node），参考服务为
  `ccserver.services.{gateway,login,lobby,world}`，由 `app/config/topology.lua` 决定哪个服务跑在哪个节点。
  服务代码按逻辑名路由（`router.call("login", ...)`），本地/远程对代码透明。详见 `docs/architecture.md`。
- **Actor 模型**：Lua service 通过类型化消息（`PTYPE_*`）通信；Rust 负责异步 I/O。
- **unique vs 非 unique**：`unique = true` 的 actor 跑在专用 OS 线程 + 阻塞接收；否则是 Tokio task。
- **每-actor 内存**：自定义 Lua 分配器按 actor 记账，支持内存上限。
- **启动链路**：`main()` → Tokio runtime → `async_main()` → 信号 → logger → monitor/timer →
  bootstrap Lua actor → 事件循环至退出。
- **关注点**：`moon-game` 保持 **零 Lua/FFI 依赖**，纯算法、可单测、可 benchmark；
  与 Lua 的桥接一律放在 `moon-runtime`。

---

## §8 路线图与状态

> 状态图例：`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成。每轮同步此表与 `STATE.md`。

- [x] **P0 基线**：fork moon_rs、验证构建、建立自更新 AGENTS.md 与记忆层。
- [~] **P1 工程化**：`rust-toolchain.toml` 已定；待补 fmt/clippy/test CI、贡献规范。
- [~] **P2 骨架**：配置热更（`moon.config`）、一键启停脚本、数据备份/恢复（`scripts/backup.sh`/`restore.sh`）、
  `Makefile`、`docker-compose.yml`（含持久化卷）已就绪；待补启动脚手架模板。
- [ ] **P3 网络层**：TCP/KCP 帧协议、session 管理、协议编解码（protobuf）。
- [~] **P4 游戏通用层**：AOI/math 已有纯 Rust 基础；待补实体/房间/事件总线/匹配/排行。
- [~] **P5 数据层**：统一 `moon.db`（Redis + SQLx[MySQL/PG/SQLite] + 可选 Mongo/pg）、
  结构迁移（`moon.db.migration`）、配置热更、集成测试已就绪；待补热更分发与连接池调优。
- [ ] **P6 分布式**：cluster 节点发现、跨服消息、网关/世界服/大厅服拆分。
- [~] **P7 示例与压测**：`example_db` / `example_server` 与 db/migration/hotreload 测试已就绪；
  待补完整游戏 demo 与 benchmark。

> **成熟化路线（M1–M6，详见 `docs/architecture.md`）**：
> [x] M1 服务拓扑骨架（gateway/login/lobby/world + node/router/topology）·
> [x] M2 统一协议与会话（`docs/protocol.md`：帧协议/版本协商/token/session/顶号）·
> [ ] M3 数据/配置硬化 · [ ] M4 可观测性 ·
> [ ] M5 可靠性与安全 · [ ] M6 CI/CD 与压测。

---

## §9 记忆层（docs/agent/）

| 文件 | 作用 |
| --- | --- |
| `docs/agent/STATE.md` | 当前状态：进度、进行中、阻塞、坑 |
| `docs/agent/TODO.md` | 任务队列（按优先级） |
| `docs/agent/DECISIONS.md` | 架构决策记录（ADR） |

这三者与 `AGENTS.md` 共同构成“自更新记忆”。格式要求见 §0；`cargo xtask agent-check` 会校验。

---

## §10 提交与发布

- 提交信息：`<type>(<scope>): <summary>`，type ∈ `feat|fix|docs|refactor|test|chore|perf|build|ci`。
- 一次提交只做一件事；提交前跑 `cargo check --workspace` 与 `cargo xtask agent-check`。
- 仅在用户明确要求时提交/推送；首个里程碑建议打 tag `v0.1.0`。
- 推送目标：`https://github.com/ccs0319/ccserver`。

---

## §11 变更日志

| 日期 | 版本 | 摘要 |
| --- | --- | --- |
| 2026-10-09 | 0.5.0 | M2 协议与会话：`ccserver/protocol.lua`（帧协议/版本协商/msgid 注册）、gateway 接入客户端（HELLO/LOGIN/ENTER/MOVE/PING）、session 绑定与顶号、`docs/protocol.md`、`test_gateway`（实测通过）。 |
| 2026-10-09 | 0.4.0 | 服务拓扑骨架 M1：`lualib/ccserver/`（service/router/topology/node + 参考服务 gateway/login/lobby/world）、`app/`（main + config/topology）、`docs/architecture.md`、`test_topology`（实测通过）。 |
| 2026-10-08 | 0.3.0 | 运维：数据库备份/恢复（`scripts/backup.sh`/`restore.sh`，保留策略）、`docker-compose.yml` 命名卷持久化、`docs/backup.md`；明确单进程多线程模型。 |
| 2026-10-08 | 0.2.0 | 数据层：统一 `moon.db`（Redis+SQLx+可选 Mongo/pg）、结构迁移 `moon.db.migration`、配置热更 `moon.config`、代码热更 `moon.hotreload`；基础设施：`docker-compose.yml`、`scripts/*`、`Makefile`；确立 fork+upstream rebase 同步策略。 |
| 2026-10-08 | 0.1.0 | 初始化：fork moon_rs@272c9b8，建立自更新 AGENTS.md + docs/agent 记忆层 + `xtask agent-check`。 |

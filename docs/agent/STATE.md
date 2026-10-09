# STATE — ccserver 当前状态

<!-- agent-state
last_updated: 2026-10-09
phase: M4
-->

> 本文件由 agent 按 `AGENTS.md` §0 协议维护。只写事实、进度、阻塞与已知坑。

## 当前阶段

**M4 可观测性（已完成）**，进入 **M5 可靠性与安全**。成熟化路线见 `docs/architecture.md`。

## 进行中

- [ ] M5：限流、熔断、优雅 drain、密钥隔离、定时+校验备份。
- [ ] 补 CI（fmt/clippy/test）与贡献规范（P1）。

## 已完成

- [x] fork `moon_rs@272c9b8`；历史以基线为根（`272c9b8 → delta`），`scripts/update-upstream.sh` 可 rebase。
- [x] 自更新 `AGENTS.md` + `docs/agent/` 记忆层 + `cargo xtask agent-check`；stable 工具链，`cargo check` 通过。
- [x] 数据层：`moon.db`（Redis+SQLx+可选 Mongo/pg）、`moon.db.migration` 结构迁移、`namesearch` 迁 SQLx、`sqlite::memory:` 修复。
- [x] 热更：`moon.config`（配置）+ `moon.hotreload`（hotfix 代码）。
- [x] 运维：`docker-compose.yml`（命名卷）、`scripts/{start,stop,restart,status,dev,db-*,backup,restore,update-upstream}.sh`、`Makefile`、`docs/backup.md`。
- [x] **M1 服务拓扑**：`lualib/ccserver/{service,router,topology,node}.lua` + 参考服务 `ccserver.services.{gateway,login,lobby,world}`；`app/main.lua` + `app/config/topology.lua`；`docs/architecture.md`。
- [x] **M2 协议与会话**：`ccserver/protocol.lua`（帧协议/版本协商/msgid 注册）；gateway 接入客户端（HELLO/LOGIN/ENTER/MOVE/PING）、session 绑定与顶号；`docs/protocol.md`。
- [x] **M3 数据/配置硬化**：`moon.config` 分层+校验+校验式热更；`moon.db.migration` 校验和+并发锁+verify+rollback；`moon.db` health/backend/stats。
- [x] **M4 可观测性**：`ccserver.metrics`（Prometheus）/`health`/`trace`；admin 服务 `/health` `/ready` `/metrics` `/stats`（聚合各服务指标）；gateway 接入指标与 trace。
- [x] 测试（实测通过）：`test_db_stack`、`test_migration`、`test_hotreload`、`test_topology`、`test_gateway`、`test_config`、`test_observability`。

## 阻塞项

- 无。

## 已知坑

- **Lua 多返回值陷阱**：函数调用若非**最后一个参数**，其多返回值会被截断为 1 个。
  `f(s, table.unpack(args), seq)` 只传一个 arg；应把额外值并入 args 后 `f(s, table.unpack(args))`。
- **socket 回调内不可 yield**：消息回调协程被池化，处理器需 `moon.async` 派生协程后再 `moon.call`。
- **服务是独立 actor（各自 lua_State）**：`cluster` 模块的 `NODE` 是 per-state 值，服务内不可依赖它做本地判断。
  `ccserver.router` 采用**本地优先**：按 `service_nodes` 映射比较自身 node，本地走 `moon.call`，远程才走 `cluster.call`。
  服务通过 `new_service` 的 `routing`/`node` 参数获得映射并 `router.configure`。
- **服务需 `unique = true`** 才能按名字寻址（`moon.query(name)` 只对 unique 有效），cluster 路由也依赖名字。
- `loadfile` 在本运行时返回陈旧内容：读 Lua 文件用 `load(io.readfile(path), "@"..path)`。
- SQLite 内存库用 `sqlite::memory:`（`sqlite://memory:` 会落盘）；连接池设 `max_connections=1`。
- Lua 5.5 `for` 循环变量是 const，循环体内不可赋值。
- `crates/moon-base/build.rs` 编译 Lua 5.5 C 源码；`links="lua54"` 为历史遗留。
- 上游 README 称需 nightly，实测 stable 1.96.0 可编译。
- 进程模型：单进程多线程；多节点用 `cluster`（各节点独立进程）。
- 备份脚本 Redis 恢复仅支持容器模式；宿主机 Redis 需手动。

## 上游同步

- 策略：**fork + upstream rebase**（`scripts/update-upstream.sh`）。
- 本地对上游改动（保持最小）：`crates/moon-runtime/Cargo.toml`（默认 feature）、`crates/moon-runtime/src/modules/lua_sqlx.rs`（SQLite 前缀）。
- repo: `https://github.com/sniper00/moon_rs`；baseline: `272c9b8f035decd60bf3cb4e4930c75eb0f47217`（2026-09-30）

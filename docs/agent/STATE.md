# STATE — ccserver 当前状态

<!-- agent-state
last_updated: 2026-10-13
phase: M6
-->

> 本文件由 agent 按 `AGENTS.md` §0 协议维护。只写事实、进度、阻塞与已知坑。

## 当前阶段

**M1–M6 全部完成；world 分片 + 2 节点跨节点路由 + etcd 生产化发现均已实测。** 框架 stable。

## 进行中

- [ ] 更多端到端测试与压测扩展（多节点压测、长稳测试）。
- [ ] 会话跨网关迁移（gateway 无状态化）——当前会话绑定在单个 gateway。

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
- [x] **M5 可靠性与安全**：`ccserver.ratelimit`/`breaker`/`secrets`；gateway 每连接限流 + 优雅 drain；`scripts/verify-backup.sh` 备份 sha256 校验。
- [x] **M6 CI/CD 与压测**：`.github/workflows/ci.yml`（fmt/clippy/test/build/lua-tests/db-tests）；`benchmark_gateway.lua` + `scripts/bench.sh` + `docs/benchmark.md`（单机 ~170k req/s）。
- [x] **world 分片 + 多节点**：world 按 `config.zone` 分片（world_1..N），gateway 按 zone 路由；`topology.multinode.lua` + `scripts/{run,stop}-cluster.sh`；`test_sharding`（单机）、`test_multinode`（2 节点跨节点实测通过）。
- [x] **etcd 生产化发现**：`ccserver.discovery`（etcd 注册 + lease/keepalive）+ `app/discovery.lua` adapter；`topology.etcd.lua` + `scripts/run-cluster-etcd.sh`；实测跨节点路由与**租约过期自动注销**（`make test-multinode-etcd`）。
- [x] **多实例与容灾**：`ccserver.router` 服务组（轮询 + 熔断 + failover）；lobby 多实例（lobby_1/lobby_2）；`test_failover` 实测通过。
- [x] **会话跨网关（无状态化）**：`ccserver.session`（memory/redis 共享会话所有权）；gateway ENTER 读写共享会话并跨网关顶号（`router.call(prev.gateway,"kick",uid)`）；`test_session` 实测通过（需 Redis）。
- [x] **工程化**：`CONTRIBUTING.md`；`scripts/smoke.sh`（`make smoke` 端到端）。
- [x] **模块化消息**：拓扑里模块声明 `client = { msg = cmd }`；`protocol.build` 确定性分配 msgid（≥1000，组→逻辑名，去重）；网关自动转发到服务命令；admin `/messages`；`test_module_messages` 实测通过。
- [x] **客户端协议库 `sdk/ccsclient`**：Rust 帧+编解码（对齐协议），传输由宿主提供；`native` TCP + `wasm` 导出（微信小游戏 JS 持 socket）；wasm32/iOS/Android/Windows 目标编译通过，单测 4/4。
- [x] **对外协议 payload 可切换**：`protocol.set_codec("seri"|"json"|"raw")`（拓扑 `protocol.codec`/env）；客户端 `ccsclient` 增 `json` 特征；`test_protocol_codec` 实测通过。
- [x] **WebSocket 传输**：网关传输无关（TCP + WS 同一套处理器，`ws_addr`）；`test_gateway_ws` 实测；`ccsclient` 增原生 WS 传输（tungstenite）+ 分帧模式 + protobuf 示例；`examples/ws_client.rs` 对 app 实测通过。
- [x] 测试（实测通过）：`test_db_stack`、`test_migration`、`test_hotreload`、`test_topology`、`test_gateway`、`test_sharding`、`test_failover`、`test_multinode`、`test_config`、`test_observability`、`test_reliability`；`cargo test --workspace` 210 passed。

## 阻塞项

- 无。

## 已知坑

- **Lua 多返回值陷阱**：函数调用若非**最后一个参数**，其多返回值会被截断为 1 个。
  `f(s, table.unpack(args), seq)` 只传一个 arg；应把额外值并入 args 后 `f(s, table.unpack(args))`。
- **网关处理器签名**：`handler(session, seq, ...args)` —— `seq` 固定为第二个参数，
  避免客户端省略尾部参数时 `seq` 错位（曾导致 `MOVE` 响应 seq 丢失、客户端挂起）。
- **Redis 连接池按名全局注册**：同一进程内多个 actor 用**同名**连接会互相顶掉（"shutting down the previous pool"）；
  每实例用独立名（如 `gw_session_<service>`）。
- **actor init 内不可 yield**：service 的 `on_start` 在 C 调用链中执行，若其中直接 `moon.wait`（如 redis connect）
  会报 "cannot resume dead coroutine"；需 `moon.async` 派生协程做异步初始化。
- **`new_service` 参数序列化**：参数经 `print_r` 转成 Lua 字面量，**带点的字符串键（如 `["a.b"]`）会写成非法 Lua**；
  传给服务的数据结构避免点键（`protocol.build` 的 `ids` 用嵌套 `ids[service][msg]`）。
- **组=负载均衡**：模块消息/服务调用若路由到**组**，会在实例间轮询；**有状态命令不能放进组**
  （各实例内存独立），有状态逻辑要么单实例、要么外置共享（Redis）。
- **socket 回调内不可 yield**：消息回调协程被池化，处理器需 `moon.async` 派生协程后再 `moon.call`。
- **服务是独立 actor（各自 lua_State）**：`cluster` 模块的 `NODE` 是 per-state 值，服务内不可依赖它做本地判断。  `ccserver.router` 采用**本地优先**：按 `service_nodes` 映射比较自身 node，本地走 `moon.call`，远程才走 `cluster.call`。
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

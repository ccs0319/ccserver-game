# DECISIONS — ccserver 架构决策记录（ADR）

> 追加式记录。不要删除历史条目；变更用新 ADR 并标注 `Supersedes: ADR-NNN`。
> 每条格式：`## ADR-NNN: 标题`、`- Date`、`- Status`、`- Context`、`- Decision`、`- Consequences`。

## ADR-001: 以 fork 改造方式基于 moon_rs 构建 ccserver

- Date: 2026-10-08
- Status: Accepted
- Context: 需要一个可复用的游戏服务器框架，希望直接复用 moon_rs 成熟的 Lua Actor 运行时
  （Tokio 驱动、原生网络/数据库模块），同时保留按游戏域演进的空间。
- Decision: 将 `moon_rs@272c9b8` 作为源码基线 fork 到 `ccs0319/ccserver` 后直接改造，
  保留 MIT 许可与上游署名；不在其之上做“薄依赖层”。
- Consequences: 需自行处理上游同步（记录 baseline commit）；可自由改动内核以满足游戏域需求；
  必须遵守 `AGENTS.md` 的硬性规则以避免破坏既有 API。

## ADR-002: 自更新记忆层作为 agent 协作的单一事实源

- Date: 2026-10-08
- Status: Accepted
- Context: 多轮、多 agent 协作容易产生上下文丢失与文档漂移（尤其来自上游的 `claude.md`）。
- Decision: 以根目录 `AGENTS.md` 为唯一权威指南，配套 `docs/agent/{STATE,TODO,DECISIONS}.md`
  记忆层；在 `AGENTS.md` §0 定义强制回写协议，并提供 `cargo xtask agent-check` 做格式校验。
- Consequences: 每轮收尾必须更新记忆层；`claude.md` 等旧文件降级为指针，避免与 `AGENTS.md` 冲突。

## ADR-003: 数据库栈收敛为 Redis + SQLx（+ 可选 Mongo/pg）

- Date: 2026-10-08
- Status: Accepted
- Context: 上游同时提供手写 PostgreSQL 线协议（`lua_pg`）、SQLx（MySQL/PG/SQLite）、
  MongoDB、Redis，关系型路径重叠。需要一个清晰、低维护的默认组合。
- Decision: 默认 feature 收敛为 **Redis + SQLx**；关系型统一走 SQLx 一套 API；
  `pg`（手写 PG 驱动）与 `mongodb` 降为**可选 feature**（保留代码，不删除已验证的高性能驱动）；
  新增统一管理器 `lualib/moon/db.lua`。`namesearch` 迁移到 SQLx（PostgreSQL 后端）。
- Consequences: 默认构建更小更聚焦；需要高性能 PG 或文档存储时用 `--features pg,mongodb` 显式开启；
  `pg` 与 SQLx 两条 PG 路径仍并存，长期需评估是否彻底移除或上游化。

## ADR-004: 上游同步采用 fork + rebase（非依赖/submodule）

- Date: 2026-10-08
- Status: Accepted
- Context: 需要方便地跟进 moon_rs 最新代码。moon_rs 未发布到 crates.io；`moon-app` 仅 bin 无 lib；
  `lualib`/`assets`/`xtask` 非 crate，无法仅靠 Cargo 依赖消费；且我们已对上游做小幅修改。
- Decision: 保留 fork，将本仓库历史 **以上游基线 commit 为根**，我们的改动作为薄 delta；
  提供 `scripts/update-upstream.sh`（fetch + rebase）。新增能力优先放新 crate / 新 Lua 文件，
  尽量不改上游文件；必须改时保持最小并在本文件记录。
- Consequences: 更新上游 = 一条命令 rebase；delta 越大冲突越多，因此需持续抑制对上游文件的改动；
  当前 delta 仅 `moon-runtime/Cargo.toml` 与 `lua_sqlx.rs` 两处，可考虑上游化以归零。

## ADR-005: 热更实现基于 hotfix + 内容轮询，规避 loadfile 缓存

- Date: 2026-10-08
- Status: Accepted
- Context: 需要配置热更与代码热更。本运行时的 `loadfile` 对同尺寸改写文件会返回陈旧内容，
  导致热更失效；上游已有 `lualib/hotfix.lua` 做函数级原地替换。
- Decision: 读 Lua 文件统一用 `load(io.readfile(path), "@"..path)`；代码热更封装为
  `lualib/moon/hotreload.lua`（注册文件系统 searcher + 轮询内容变化 + `hotfix.update`），
  配置热更为 `lualib/moon/config.lua`。模块需经 `hotreload.require` 加载才能原地热更。
- Consequences: 每个 actor 各自轮询/热更自身状态，跨服务重载需另行广播（列为 TODO）；
  `hotfix` 对 upvalue 敏感，热更代码需保持函数原型兼容。

## ADR-006: 数据库备份/恢复以脚本 + 命名卷实现，生产另行加保

- Date: 2026-10-08
- Status: Accepted
- Context: 需要数据库的定期备份能力。此前 `docker-compose.yml` 无命名卷，数据仅存于容器可写层，
  `docker rm` 即丢失；也没有备份/恢复工具。
- Decision: 为 compose 增加命名卷持久化；提供 `scripts/backup.sh`（mysqldump / pg_dump /
  mongodump / redis-cli，时间戳目录 + 保留策略 `CCS_BACKUP_KEEP`）与 `scripts/restore.sh`；
  定时化交给宿主 cron（见 `docs/backup.md`），异地/生产级备份（binlog、WAL 归档、副本、云托管）在文档中给出指引。
- Consequences: 本地开发即可一键备份/恢复（实测 MySQL/PG 还原成功）；Redis 恢复仅支持容器模式；
  生产环境仍需额外的 PITR/副本/异地存储，脚本本身不覆盖这些。

## ADR-007: 以服务边界划分游戏服务器（gateway/login/lobby/world）

- Date: 2026-10-09
- Status: Accepted
- Context: 单进程塞入登录与游戏内服务不利于隔离、伸缩与安全。需要明确的服务边界与可拆分拓扑。
- Decision: 框架层引入 `lualib/ccserver/`（service/router/topology/node），参考服务划分为
  **gateway**（接入/会话，不持密钥）、**login**（鉴权/发 token，唯一持密钥）、**lobby**（社交/匹配）、
  **world**（有状态，按区/线分服）。由 `app/config/topology.lua` 决定服务跑在哪个节点；
  开发期可同进程，上线按 `cluster` 拆进程，代码零改动。
- Consequences: 服务代码只按逻辑名路由；拆分是配置项而非重构。当前 `world` 单实例，
  分片（world_1..N）与多节点发现（etcd）列为 M2/M6 落地。

## ADR-008: 服务路由采用「本地优先」，不依赖 cluster 的 per-state NODE

- Date: 2026-10-09
- Status: Accepted
- Context: 每个 service 是独立 actor、拥有独立 lua_State；`cluster` Lua 封装的 `NODE` 是 per-state
  值，服务内未初始化，若用它判断本地/远程会把本地调用误走网络。
- Decision: `ccserver.router` 依据 `topology.service_nodes` 的 `service -> node` 映射与自身 node 比较：
  本地目标走 `moon.call`/`moon.send`（不依赖 cluster），仅远程目标走 `cluster.call`/`cluster.send`。
  服务通过 `new_service` 的 `node`/`routing` 参数获得映射并在启动时 `router.configure`。
- Consequences: 本地调用无 cluster 依赖、更快且可在无 discovery 的单机模式下工作；
  服务必须是 `unique = true`（按名寻址）。多节点时远程调用仍依赖 cluster 已初始化（进程级）。

## ADR-009: 客户端协议与会话（网关边缘、token、顶号）

- Date: 2026-10-09
- Status: Accepted
- Context: 需要统一的客户端协议与安全的会话模型，且网关不应持有鉴权密钥。
- Decision: 定义 `ccserver.protocol` 帧内协议（version/type/msgid/seq + seri payload），
  传输帧复用运行时 `socket` 帧协议；网关作为边缘，负责版本协商、解析、路由与 session 管理；
  LOGIN 只做鉴权并发 token，**ENTER 才绑定 `fd→uid`**；同一 uid 新登录对旧连接发 `KICK` 并关闭（顶号）；
  token 无状态（login 校验），故重连只需重发 ENTER。网关不存密码/签名密钥。
- Consequences: 协议演进显式（版本不匹配拒绝并断开）；顶号/重连语义明确；payload 暂用 seri，
  后续可替换为 protobuf；心跳超时回收与限流留待 M5。

## ADR-010: 服务处理器用 `moon.async` 派生，避免 socket 回调内 yield

- Date: 2026-10-09
- Status: Accepted
- Context: socket 消息回调运行在**池化**协程中，回调内直接 yield（如 `router.call`）会导致挂起/复用异常；
  且 Lua 中非末尾的多返回值参数会被截断为 1 个，曾导致 `handler(s, table.unpack(args), seq)` 丢失参数。
- Decision: socket 回调内不 yield，改为 `moon.async` 派生独立协程执行可能阻塞的处理器；
  传参时把额外参数并入 args 表，使 `table.unpack(args)` 位于调用末尾以完整展开。
- Consequences: 网关处理器可安全调用后端服务；`service.lua` 分发同样用 `table.pack/unpack` 保留多返回值。

## ADR-011: 配置采用分层合并 + schema 校验 + 校验式热更

- Date: 2026-10-09
- Status: Accepted
- Context: 配置需要支持环境覆盖、结构约束与安全热更，避免错误配置在运行期才暴露。
- Decision: `moon.config` 提供 `merge`（深合并）、`load_layered`（多文件左到右覆盖）、
  `validate(cfg, schema)`（类型/必填校验，报错带路径）、`watch(..., { schema })`（非法热更被拒绝、保留旧值）。
- Consequences: 配置错误在加载/热更时即被拒绝；密钥不入库（运行时从 env/secret 合并）；
  事件驱动监听与跨服务广播仍待 M3 后续或 M4。

## ADR-012: 迁移增加校验和、并发锁与回滚

- Date: 2026-10-09
- Status: Accepted
- Context: 基础迁移可能被并发实例重复执行，且已应用迁移被静默修改无法察觉。
- Decision: `schema_migrations` 记录 `checksum`（djb2，无依赖）；`run` 在给定 `opts.backend` 时取
  数据库咨询锁（MySQL `GET_LOCK` / PostgreSQL `pg_advisory_lock`）避免并发双跑；
  `verify` 比对已应用迁移的校验和以发现篡改；`rollback(n)` 执行迁移文件的 `down`。
  旧表通过 `ALTER TABLE ADD COLUMN checksum` 平滑升级。
- Consequences: 多节点启动安全；迁移文件改动可被检出；支持回滚。SQLite/未知后端不加锁（单写者）。

## ADR-013: 可观测性（metrics/health/trace + admin 端点）

- Date: 2026-10-09
- Status: Accepted
- Context: 需要成熟的可观测能力（指标、健康探针、请求追踪）以支撑运维与压测。
- Decision: 提供 `ccserver.metrics`（Prometheus 文本）、`ccserver.health`（探针注册表）、
  `ccserver.trace`（协程本地 trace id）；新增 **admin 服务** 暴露 `/health` `/ready` `/metrics` `/stats`。
  指标为 per-actor；`/metrics` 由 admin 通过内置 `metrics` 命令 **RPC 聚合各服务**后合并
  （跨节点可经 cluster 聚合）。所有服务内置 `metrics`/`info`/`stats` 命令。
- Consequences: 运维可直接抓取 `/metrics`、用 `/ready` 做就绪探针；网关已接入连接/消息/延迟指标与 trace。
  局限：无原生进程级指标聚合（靠 RPC 扇出）、无 OpenTelemetry span 导出，列为后续。

## ADR-014: 可靠性与安全采用边缘限流 + 熔断 + 优雅 drain + 密钥隔离

- Date: 2026-10-10
- Status: Accepted
- Context: 需要防护过载/下游故障、平滑停机与密钥不落库。
- Decision: `ccserver.ratelimit`（令牌桶，gateway 每连接限流，超限返回 ERROR 并计入指标）；
  `ccserver.breaker`（按下游服务熔断，open→half_open→closed）；gateway 停机时**优雅 drain**
  （停收新连接→等待 in-flight→关闭剩余连接）；`ccserver.secrets`（env/文件加载 + redact，密钥不入配置库）。
- Consequences: 单连接可被限速、下游故障快速失败、停机不丢在途请求、密钥可安全注入。
  局限：限流仅按连接（未按 uid/命令）、熔断需显式包裹调用，列为后续。

## ADR-015: 备份加入 sha256 清单与独立校验脚本

- Date: 2026-10-10
- Status: Accepted
- Context: 备份可能静默损坏，需要可验证的完整性。
- Decision: `scripts/backup.sh` 的 MANIFEST 记录每个文件的 size + sha256；新增 `scripts/verify-backup.sh`
  重算并比对，缺失/尺寸/哈希不符即非零退出（可挂 cron 告警）。`make verify-backup`。
- Consequences: 备份可校验；篡改/损坏可被检出。局限：未做恢复演练式校验（restore 到临时库）与异地存储，列为后续。

## ADR-016: CI 采用 GitHub Actions，fmt/clippy/test/build + Lua/db 集成测试

- Date: 2026-10-10
- Status: Accepted
- Context: 需要自动化质量门禁与回归。
- Decision: 新增 `.github/workflows/ci.yml`：`lint`（`cargo fmt --check` + `cargo clippy --workspace --all-targets`）、
  `test`（`cargo xtask agent-check` + `cargo test --workspace`）、`build`、`lua-tests`（无需外部服务的 Lua 集成测试）、
  `db-tests`（用 GitHub services 起 Redis/MySQL/PostgreSQL 跑 `test_db_stack`/`test_migration`）。
  clippy 对上游少量 warning 不 deny（遵循 ADR-004 不重排上游）。
- Consequences: push/PR 自动跑 fmt/clippy/test/build 与集成测试；上游 warning 不阻塞但可见。

## ADR-017: 压测用独立客户端进程 + 一键脚本，修复网关参数错位

- Date: 2026-10-10
- Status: Accepted
- Context: 需要可复现的单机容量基线与负载工具。
- Decision: `assets/benchmark/benchmark_gateway.lua` 作为独立 moon_rs 进程连接运行中的网关做压测
  （HELLO/LOGIN/ENTER 后按命令循环，报告吞吐与 p50/p90/p99）；`scripts/bench.sh` 一键起服（禁用限流）→压测→停服；
  `docs/benchmark.md` 记录基线（~170k req/s）与注意事项。
  压测暴露并修复了网关处理器签名 bug：`seq` 改为**固定第二参数** `handler(session, seq, ...)`，避免省略尾部参数导致错位。
- Consequences: 有可复现的单机基线与回归手段；处理器签名约定写入 STATE 已知坑。局限：同机压测为下界，未做分布式压测。









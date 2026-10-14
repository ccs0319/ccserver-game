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

## ADR-018: world 按 zone 分片，多节点用 cluster 跨进程路由

- Date: 2026-10-12
- Status: Accepted
- Context: 单 actor world 是吞吐上限；需要按区/线水平拆分并验证跨进程路由。
- Decision: world 服务实例携带 `config.zone`，命名 `world_1..N`；gateway 以 `config.worlds`（zone→服务名）
  路由 ENTER/MOVE；`router` 对本地分片走 `moon.call`、对异地分片走 `cluster.call`（透明）。
  提供 `app/config/topology.multinode.lua`（node1: gateway/login/lobby/world_1/admin；node2: world_2）+
  `scripts/{run,stop}-cluster.sh`（HTTP discovery + 2 节点）。
- Consequences: 单机可多分片、跨机可分节点，代码零改动；已实测 zone2 请求经 node1 网关落到 node2 的 world_2。
  局限：示例用 HTTP registry（生产用 etcd）、未做 gateway/lobby 多实例与故障转移，列为后续。

## ADR-019: 生产化节点发现用 etcd（lease）+ HTTP adapter

- Date: 2026-10-13
- Status: Accepted
- Context: 静态 node.json 无法满足生产（动态上下线、故障自动注销）。原生 cluster 模块的发现契约是
  HTTP（`GET discovery_url` 返回 host:port），与 etcd 的 gRPC API 不匹配。
- Decision: 节点用 `ccserver.discovery` 直连 etcd（gRPC，`moon.db.etcd`）注册 `<prefix><node_id>` 并持
  **lease + keepalive**（节点死亡→租约过期→自动注销）；另起 `app/discovery.lua` **HTTP adapter** 读 etcd 并
  按 cluster 契约应答 `/cluster?node=N`（只读）。节点需 `CCS_CLUSTER_ADDR`（自身 cluster 地址）。
  etcd 客户端复用 `assets/example/grpc/etcd.pb` 描述符（自动探测路径，可 `CCS_ETCD_PROTO` 覆盖）。
- Consequences: 动态发现 + 故障自动注销（已实测：停 node2 后 TTL 到期从 etcd 消失）；adapter 为单点读服务，
  生产需冗余部署；未来若 cluster 模块支持非 HTTP 发现可省去 adapter。

## ADR-020: 逻辑服务用「服务组」做多实例轮询与 failover

- Date: 2026-10-13
- Status: Accepted
- Context: 单一实例是单点；需要同一逻辑服务（如 lobby）多实例部署、负载均衡与故障转移。
- Decision: topology 增加 `groups`（逻辑名 → 实例名列表）；`ccserver.router` 对组名做**轮询**分发，
  单个实例失败（连接错/处理器返回 false/熔断打开）时**failover** 到下一个实例，并用 `ccserver.breaker`
  按实例熔断。服务实例名以 `new_service` 注册名（`conf.name`）为准（`info`/日志据此标识实例）。
- Consequences: lobby_1/lobby_2 轮询 + 停一个自动切换（`test_failover` 实测）；gateway 侧 ENTER 经组名路由。
  注意：failover 会重试，处理器需幂等或容忍重试；会话仍绑定在单个 gateway（跨网关迁移列为后续）。

## ADR-021: 会话所有权外置到共享存储，实现跨网关顶号

- Date: 2026-10-13
- Status: Accepted
- Context: 会话原为 gateway 本地状态，多网关下同一账号可在不同网关各持一个会话（无法跨网关顶号）。
- Decision: 新增 `ccserver.session`（后端 `memory` 单机 / `redis` 共享，含 TTL）；gateway 在 ENTER 时读共享会话，
  若属主是**其它网关**则 `router.call(prev.gateway, "kick", uid)`（本地或经 cluster）令其踢线，再写入新属主；
  断开时仅当自己仍是属主才删除。每网关用独立 redis 连接名（进程级池按名注册，同名会互相顶掉）。
- Consequences: 跨网关/跨进程顶号成立（`test_session` 实测，需 Redis）；客户端可重连到任意网关（token 无状态，重发 ENTER）。
  gateway 对会话只保留连接（fd），属主信息外置，为无状态化铺路。注意 redis 连接名与 init 内不可 yield 的约束。

## ADR-022: 模块化客户端消息（拓扑声明 + 网关自动转发）

- Date: 2026-10-14
- Status: Accepted
- Context: 新模块的客户端消息原先要改两个中心文件（`protocol.MSG` 消息号表 + gateway `handlers`），
  模块不内聚、多人易冲突。
- Decision: 模块在拓扑里声明 `client = { <客户端消息> = <命令> }`；`protocol.build(cfg)` 按**确定性顺序**
  （逻辑名排序、消息名排序）从 **1000** 起分配 msgid（内建消息占 1–99）；若声明服务在**组**中，
  路由指向**逻辑组名**并去重；网关对模块 msgid **自动转发** `router.call(service, cmd, uid, ...)`，
  无 per-message 处理器；`admin /messages` 暴露 id→名 供客户端取用。
- Consequences: 加模块 = 加服务文件 + 拓扑声明（不动 protocol/gateway 中心文件）；所有节点消息号一致。
  注意：转发到组会负载均衡 → 命令须无状态；传给服务的结构避免点键（`print_r` 序列化限制）。

## ADR-023: 客户端库只做协议编解码，传输由宿主提供（微信走 JS socket）

- Date: 2026-10-14
- Status: Accepted
- Context: 需要一套跨 macOS/Windows/iOS/Android/微信小游戏的客户端底层库。微信小游戏网络**必须**走
  自有 API（`wx.connectSocket`/`wx.createTCPSocket`），且 **WASM 无法直接开 socket**；不同平台传输方式不同。
- Decision: `sdk/ccsclient`（Rust）**只负责帧 + 协议编解码**（对齐 `ccserver/protocol.lua`），
  `payload` 为不透明字节；传输抽象为 `Transport`：原生用内置 TCP（`native`），
  微信/浏览器编译为 WASM（`wasm`）由 **JS 持有 socket**（`wx.connectSocket`）并调用导出的
  `encode_request`/`Decoder`。独立 Cargo workspace（`[workspace]` 自持，不与服务器工作区耦合）。
- Consequences: 一套 Rust 逻辑覆盖全部目标（已验证 wasm32/iOS/Android/Windows 可编译）；微信网络限制
  （域名白名单、5 连接上限）由宿主遵守。局限：payload 编解码留给宿主（当前服务器用 seri，需对齐或切换为
  JSON/protobuf）；重连/心跳策略未封装。

## ADR-024: 对外协议 payload 编解码可切换（seri/json/raw）

- Date: 2026-10-14
- Status: Accepted
- Context: 服务端内部用 seri（Lua 原生、快），但异构客户端（Rust/JS/WASM）无法直接用 seri；
  需要按部署选择载荷编码。
- Decision: `ccserver.protocol` 增加 `set_codec("seri"|"json"|"raw")`（拓扑 `protocol.codec`，env
  `CCS_PROTOCOL_CODEC`，默认 seri）；`json` 把参数编成 JSON 数组，`raw` 原样透传（供 protobuf）。
  网关从拓扑读取并设置；客户端必须用同一种编码。`ccsclient` 增 `json` 特征（serde 帮助函数），
  protobuf 由调用方用 prost 编码后作为 raw payload。
- Consequences: 服务端内部仍用 seri；对外可按客户端能力选 json（简单）或 raw+protobuf（紧凑/快）。
  `test_protocol_codec` 验证 JSON 端到端。注意：两端编码必须一致。
















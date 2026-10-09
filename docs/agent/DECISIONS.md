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





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



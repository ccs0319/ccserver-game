# STATE — ccserver 当前状态

<!-- agent-state
last_updated: 2026-10-08
phase: P5
-->

> 本文件由 agent 按 `AGENTS.md` §0 协议维护。只写事实、进度、阻塞与已知坑。

## 当前阶段

**P5 数据层 / P2 骨架** — 进行中。已建立统一数据库层（Redis + SQLx + 可选 Mongo/pg）、
结构迁移、配置热更、代码热更、一键启停脚本与本地依赖编排。下一步补网络层与游戏通用层。

## 进行中

- [ ] 补 CI（fmt/clippy/test）与贡献规范（P1）。

## 已完成

- [x] 仓库历史重建为「以上游基线 commit 为父提交」（`272c9b8 → 2bcc752`），
  `scripts/update-upstream.sh` 的 fetch+rebase 流程已验证可用。
- [x] fork `moon_rs@272c9b8` 作为基线，建立自更新 `AGENTS.md` + `docs/agent/` 记忆层 + `xtask agent-check`。
- [x] `rust-toolchain.toml` 固定 stable；`cargo check --workspace` 通过（1.96.0）。
- [x] 统一数据库管理器 `lualib/moon/db.lua`：`db.setup{redis,sql,mongo}` + 命名句柄 + `close_all`。
- [x] 默认 feature 收敛为 Redis + SQLx（MySQL/PG/SQLite）；`pg`/`mongodb` 降为可选 feature。
- [x] 结构迁移 `lualib/moon/db/migration.lua`：`run/status`，`schema_migrations` 记账，幂等。
- [x] 配置热更 `lualib/moon/config.lua`（`load`/`watch`）；代码热更 `lualib/moon/hotreload.lua`（基于 `hotfix`）。
- [x] `namesearch` 从手写 pg 迁移到 SQLx（PostgreSQL 后端）。
- [x] 基础设施：`docker-compose.yml`（含命名卷持久化）、`scripts/{start,stop,restart,status,dev,db-up,db-down,db-reset,backup,restore,update-upstream}.sh`、`Makefile`。
- [x] 数据备份/恢复：`scripts/backup.sh`（mysqldump/pg_dump/mongodump/redis，含保留策略）、`scripts/restore.sh`；实测 MySQL/PG 还原成功。
- [x] 集成测试（实测通过）：`test_db_stack`（Redis+SQLite+MySQL+PG）、`test_migration`、`test_hotreload`。
- [x] 修复上游 SQLite 前缀判断，支持 `sqlite::memory:`（`lua_sqlx.rs`）。

## 阻塞项

- 无。

## 已知坑

- **`loadfile` 在本运行时返回陈旧内容**（同尺寸文件改写后仍读到旧版本）。读 Lua 配置/迁移/热更模块
  请用 `load(io.readfile(path), "@"..path)`，勿用 `loadfile`。
- SQLite 内存库必须用 `sqlite::memory:`（`sqlite://memory:` 会落盘成名为 `memory:` 的文件）；
  连接池设 `max_connections=1` 以避免每个连接各自独立的 `:memory:`。
- Lua 5.5 的 `for` 循环变量是 **const**：不能在循环体内对其赋值，需另起 `local`。
- `crates/moon-base/build.rs` 通过 `cc` 编译 Lua 5.5 C 源码；`links = "lua54"` 是历史遗留。
- `.gitattributes` 将 `*.c` 映射为 `linguist-language=rust`（影响 GitHub 语言统计），上游有意为之，勿删。
- Lua C API 互操作存在大量 `unsafe`；递归操作前需 `lua_checkstack`。
- 上游 README 声称 “targets Rust nightly”，实测 **stable 1.96.0 可编译通过**；本仓库固定 stable。
- 上游 CI 仅做 release 构建，无 fmt/clippy/test——本仓库需在 P1 补齐。
- **进程模型**：单进程、多线程（Tokio + unique actor 独占线程）；多节点需用 `cluster`（各节点独立进程）。
- 备份脚本的 **Redis 恢复仅支持容器模式**（`ccs-redis`，copy rdb + restart）；宿主机 Redis 需手动停服换 `dump.rdb`。

## 上游同步

- 策略：**fork + upstream rebase**（`scripts/update-upstream.sh`）。历史以上游基线为根，我们的改动是薄 delta。
- 本地对上游的改动（保持最小）：`crates/moon-runtime/Cargo.toml`（默认 feature）、
  `crates/moon-runtime/src/modules/lua_sqlx.rs`（SQLite 前缀）。
- repo: `https://github.com/sniper00/moon_rs`
- baseline: `272c9b8f035decd60bf3cb4e4930c75eb0f47217`（2026-09-30）

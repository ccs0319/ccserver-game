# TODO — ccserver 任务队列

> 按优先级排列；每轮开发按 `AGENTS.md` §0 勾选/拆分。状态：`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成。

## P0 — 基线（完成）

- [x] fork `moon_rs` 到 `ccs0319/ccserver-game`，保留 MIT 与上游署名。
- [x] 自更新 `AGENTS.md` + `docs/agent/` 记忆层 + `cargo xtask agent-check`。
- [x] `cargo check --workspace` 通过（stable 1.96.0）。
- [x] `git init` + 提交 + 推送。
- [ ] 重建历史为「以上游基线为父提交」，启用 `scripts/update-upstream.sh` 的 rebase 流程。

## P1 — 工程化

- [x] `rust-toolchain.toml`（stable）。
- [ ] CI：`cargo fmt --check`、`cargo clippy`、`cargo test`、`cargo build --release`。
- [ ] 贡献规范（CONTRIBUTING）。

## P2 — 骨架

- [x] 配置加载与热更（`moon.config`）。
- [x] 统一日志（上游 logger）+ 定时器。
- [x] 一键启停脚本 + Makefile + `docker-compose.yml`。
- [ ] 启动脚手架模板（gate/login/world 服务模板）。
- [ ] 优雅退出流程梳理与文档化。

## P3 — 网络层

- [ ] TCP/KCP 帧协议与分包。
- [ ] session 管理与心跳。
- [ ] protobuf 协议编解码约定。

## P4 — 游戏通用层

- [ ] 实体/组件模型。
- [ ] 房间/场景管理。
- [ ] AOI 与 Lua 桥接（已有纯 Rust 基础）。
- [ ] 事件总线、匹配、排行。

## P5 — 数据层

- [x] 统一 `moon.db`（Redis + SQLx[MySQL/PG/SQLite] + 可选 Mongo/pg）。
- [x] 结构迁移 `moon.db.migration`（`schema_migrations` 记账、幂等）。
- [x] 配置热更 `moon.config` + 代码热更 `moon.hotreload`。
- [x] 集成测试：`test_db_stack` / `test_migration` / `test_hotreload`。
- [ ] 热更分发（向所有 actor 广播重载）与连接池调优。
- [ ] 配置表（Excel/CSV）加载与热更。

## P6 — 分布式

- [ ] cluster 节点发现。
- [ ] 跨服消息。
- [ ] 网关/世界服/大厅服拆分。

## P7 — 示例与压测

- [x] `example_db` / `example_server` 示例。
- [ ] 登录 + 大厅 + 战斗 demo。
- [ ] 网络与 AOI benchmark。

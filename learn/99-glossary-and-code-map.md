# 99 · 术语表与代码地图

> 查词、查文件用。配合前面各篇阅读。

## 术语表

| 术语 | 一句话解释 |
| --- | --- |
| **进程** | 操作系统分配资源的单位；本框架一个二进制 = 一个进程 = 一个节点 |
| **线程** | 进程内被 CPU 调度的单位；共享进程内存 |
| **协程** | 程序自管的轻量任务；等待 I/O 时让出线程 |
| **异步** | 等待时不阻塞线程，改去跑别的任务 |
| **Actor** | 运行/隔离单元：独立内存 + 消息队列 + 串行处理 + 可寻址 |
| **Service** | 业务职责单元（gateway/login/lobby/world）；实现为一个 actor |
| **unique actor** | 独占一条 OS 线程的 actor |
| **消息** | actor 之间唯一的交互方式（send/call） |
| **send** | 单向通知，不等回复 |
| **call** | 请求/响应，等对方回 |
| **序列化** | 把值打包成字节（跨进程要）；本仓库用 `seri` |
| **协议** | 客户端与服务器的字节格式约定（版本/类型/消息号/序号/负载） |
| **拓扑（topology）** | "哪个服务跑在哪台机器"的蓝图（配置） |
| **节点（node）** | 一个进程；有 `node_id` |
| **服务发现** | 让节点互相找到地址（etcd / 静态注册表） |
| **cluster** | 跨节点 RPC |
| **分片（shard）** | 把有状态服务拆成多份（world_1..N） |
| **服务组（group）** | 同一逻辑服务的多实例（轮询+故障转移） |
| **会话（session）** | "某账号现在由谁在线"的事实，独立于连接 |
| **token** | 无状态的登录凭证，任何网关都能校验 |
| **顶号** | 同账号在新连接登录 → 踢掉旧连接 |
| **限流** | 限制每连接/玩家的速率 |
| **熔断** | 下游连续失败就快速失败，过会儿再试 |
| **优雅退出（drain）** | 停机时先停收新请求、处理完在途的再关 |
| **可观测** | 指标 + 健康检查 + 日志 + 追踪 |

## 代码地图

### 应用 / 框架（Lua）

| 路径 | 作用 |
| --- | --- |
| `app/main.lua` | 应用入口（`node.start(topology, node_id)`） |
| `app/discovery.lua` | etcd→cluster 的发现 adapter 进程入口 |
| `app/config/topology*.lua` | 拓扑：单机 / 多机 / etcd |
| `lualib/ccserver/service.lua` | 服务基类：命令分发 + 生命周期 |
| `lualib/ccserver/router.lua` | 路由：本地优先 + 服务组轮询/failover |
| `lualib/ccserver/topology.lua` | 拓扑解析/校验/映射 |
| `lualib/ccserver/node.lua` | 节点启动：cluster + 起服务 + 配路由 |
| `lualib/ccserver/protocol.lua` | 对外帧协议 + 消息表 |
| `lualib/ccserver/session.lua` | 会话属主存储（memory/redis） |
| `lualib/ccserver/discovery.lua` | etcd 注册/解析 + HTTP adapter |
| `lualib/ccserver/{metrics,health,trace}.lua` | 可观测 |
| `lualib/ccserver/{ratelimit,breaker,secrets}.lua` | 可靠性与安全 |
| `lualib/ccserver/services/*.lua` | 参考服务：gateway/login/lobby/world/admin |

### 引擎级 Lua

| 路径 | 作用 |
| --- | --- |
| `lualib/moon.lua` | 运行时 API（async/wait/dispatch/send/call） |
| `lualib/moon/socket.lua` | TCP/帧 |
| `lualib/moon/db.lua` + `db/*` | 数据库（redis/sqlx/pg/mongo/etcd/migration） |
| `lualib/moon/cluster.lua` | 跨节点 RPC |
| `lualib/moon/config.lua` / `hotreload.lua` | 配置/热更 |

### Rust 引擎

| Crate | 作用 |
| --- | --- |
| `crates/moon-base` | 内嵌 Lua 5.5 + FFI + Buffer |
| `crates/moon-runtime` | Actor 运行时 + 原生绑定 `lua_*.rs` |
| `crates/moon-app` | 二进制入口 `moon_rs` |
| `crates/moon-game` | 纯 Rust 算法（AOI/math） |
| `xtask` | 任务运行器（`agent-check`） |

### 测试 / 压测 / 运维

| 路径 | 作用 |
| --- | --- |
| `assets/test/*.lua` | 集成测试（`make test-lua` / `test-db`） |
| `assets/benchmark/benchmark_gateway.lua` | 压测（`make bench`） |
| `assets/migration/*.lua` | 迁移示例 |
| `scripts/*.sh` | 启停/集群/备份/上游同步/压测/冒烟 |
| `Makefile` | 所有命令入口（`make help`） |

## 文档索引（`docs/`）

| 文件 | 内容 |
| --- | --- |
| `architecture.md` | 总体架构 + 服务拓扑 + 多节点 |
| `protocol.md` | 协议与会话 |
| `discovery.md` | etcd 服务发现 |
| `db.md` / `config.md` / `backup.md` | 数据 / 配置 / 备份 |
| `observability.md` | 指标/健康/追踪 |
| `reliability.md` | 限流/熔断/优雅退出/密钥 |
| `benchmark.md` | 压测与容量 |
| `agent/` | 项目记忆层（STATE/TODO/DECISIONS） |

## 常用命令

```bash
make help            # 全部命令
make run / start / stop
make test-lua / test-db
make test-multinode / test-multinode-etcd
make smoke / bench
make cluster-up / cluster-down
make agent-check
```

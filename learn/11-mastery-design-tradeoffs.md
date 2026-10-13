# 11 · 精通：设计取舍与扩展

## 你将学到

把前面所有篇串起来，形成**自己的判断力**：什么时候用什么、怎么加服务、怎么分片、常见坑。

---

## 1. 本框架的六条设计原则（背下来）

1. **服务器权威**：真相在服务器，客户端只是表现。
2. **一切皆消息**：actor 之间只发消息，不共享内存 → 无锁。
3. **Actor 隔离**：一个 service = 一个 actor（独立状态、串行、可寻址）。
4. **拓扑驱动**：谁跑哪由配置决定；业务只认逻辑名；拆分不改代码。
5. **本地优先、跨进程透明**：能本地就本地，异地自动走 cluster。
6. **薄改上游**：能力优先新增，少动引擎，方便跟进上游。

## 2. 每种机制"什么时候用"速查

| 机制 | 用在 |
| --- | --- |
| Actor（service） | 任何有状态/需隔离的业务单元 |
| 消息 call | 需要结果（校验、查询） |
| 消息 send | 通知/事件（广播、日志） |
| 服务组（多实例） | **无状态/弱状态**服务（lobby、login 可多实例） |
| 分片（world_1..N） | **有状态**且单 actor 扛不住 |
| Redis 外置 | 跨服务/跨机共享、TTL 数据（会话、排行） |
| 数据库 | 持久化、要查询的数据 |
| 多进程/多节点 | 遇到 CPU/连接/单 actor/故障域墙 |
| etcd 发现 | 多节点动态上下线 |

## 3. 怎么加一个新服务（标准流程）

1. 写服务脚本 `app/services/xxx.lua`（或 `lualib/ccserver/services/`）：

```lua
local service = require("ccserver.service")
local router  = require("ccserver.router")
local commands = {}
function commands.do_something(self, ...) return ... end
service.run({ name = "xxx", commands = commands, on_start = ..., on_stop = ... }, ...)
```

2. 在 `topology.services` 注册它（`source` 指向脚本）。
3. 在 `topology.nodes[...]` 把它安置到某节点。
4. 其它服务用 `router.call("xxx", "do_something", ...)` 调用。
5. 加测试（`assets/test/test_xxx.lua`），跑 `make test-lua`。

> 记住：**服务间只能用消息**，不能 `require` 另一个服务直接调它的内存。

## 4. 怎么分片（world_1..N）

1. 服务脚本读取自己的分片配置（如 `self.config.zone`）。
2. 拓扑里定义多个实例：`world_1 = {..., config={zone=1}}`、`world_2 = {..., config={zone=2}}`。
3. 路由方按规则选分片（gateway 用 `config.worlds` 把 zone→分片）。
4. 分片可以同机（多 actor）或跨机（多节点）。
5. 测 `make test_sharding`。

## 5. 常见坑（我们都踩过，记进 STATE）

| 坑 | 现象 | 正解 |
| --- | --- | --- |
| **init 内 yield** | "cannot resume dead coroutine" | 异步初始化用 `moon.async` 派生 |
| **socket 回调内 yield** | 挂起/复用异常 | 回调用 `moon.async` 派生处理器 |
| **Lua 多返回值截断** | 参数丢失 | `table.unpack` 放调用**末尾** |
| **Redis 连接同名** | 连接被顶掉 | 每个 actor 用**独立连接名** |
| **状态放错** | 跨服务读不到/竞争 | 单服务用私有；共享用 Redis |
| **处理器不幂等** | failover 重试导致重复 | 写操作幂等或去重 |
| **无超时** | 请求永远挂着 | 所有"等外部"都设超时 |

## 6. 性能与容量思维

- 单机吞吐有上限（`make bench` 实测基线）；到顶就**加节点/分片**。
- **单 actor 是串行上限**：某分片卡 → 再分片。
- 别每条消息打数据库；热数据在内存/Redis。
- 用 `/metrics` 看瓶颈（延迟、队列、错误）。

## 7. 什么时候**不要**用这些

- 玩家很少（几百）、单机够 → 别拆服务、别上多进程。
- 强一致要求高、跨服务事务多 → 分布式会让事情更复杂，慎重拆。
- 简单工具/脚本 → 不需要 actor/拓扑这套。

> 工程的第一原则：**用最少的复杂度解决当前的问题**，并**为增长预留接口**。

## 8. 怎么读这套代码（顺序建议）

1. `app/main.lua` → `lualib/ccserver/node.lua` → `service.lua`（启动与运行）。
2. `lualib/ccserver/services/gateway.lua`（对外链路）。
3. `lualib/ccserver/router.lua` + `topology.lua`（路由与拓扑）。
4. `lualib/ccserver/protocol.lua` + `session.lua`（协议与会话）。
5. `docs/architecture.md`（全局）。

---

## 动手

1. 照着第 3 节，加一个 `echo` 服务（回显），挂到拓扑，用 `router.call` 调它，写个测试。
2. 把 `app/config/topology.lua` 的 `nodes` 改成两个节点，跑 `make test-multinode`，体会"配置即架构"。

## 记住这句

> **先服务器权威、一切皆消息、Actor 隔离；拆分靠拓扑；遇到墙才加进程/分片；能简单就别复杂。**

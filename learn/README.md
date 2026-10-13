# ccserver 学习路线（客户端程序员 → 游戏服务器）

写给**会写代码、但没做过服务器**的人。你熟悉"客户端里管理对象、更新状态、渲染"，
这里教你**同一批对象搬到服务器后，服务器该怎么设计**。全程结合本仓库的真实代码。

> 读法：**按顺序读**。每篇 5–15 分钟。每篇结尾有「动手」小任务，跑一下 `make` 命令加深印象。

## 目录

| # | 文件 | 你将理解 |
| --- | --- | --- |
| 0 | `README.md`（本文） | 全貌 + 怎么读 |
| 1 | [`01-client-vs-server.md`](01-client-vs-server.md) | 客户端思维 vs 服务器思维的根本差异 |
| 2 | [`02-lifecycle-of-a-request.md`](02-lifecycle-of-a-request.md) | 从进程启动到"登录→进入→移动"的完整链路 |
| 3 | [`03-process-thread-coroutine.md`](03-process-thread-coroutine.md) | 进程/线程/协程、同步/异步、为什么单进程多线程 |
| 4 | [`04-actor-and-service.md`](04-actor-and-service.md) | **Actor 是什么、和 Service 什么关系**（你最困惑的点） |
| 5 | [`05-service-topology.md`](05-service-topology.md) | 为什么拆成 gateway/login/lobby/world，拓扑是什么 |
| 6 | [`06-messages-and-protocol.md`](06-messages-and-protocol.md) | 内部消息 vs 对外协议，序列化，请求/响应 |
| 7 | [`07-state-and-session.md`](07-state-and-session.md) | 状态放哪、会话、顶号、无共享内存 |
| 8 | [`08-multiprocess-distributed.md`](08-multiprocess-distributed.md) | **什么时候用多进程**、分片、发现、容灾 |
| 9 | [`09-data-and-persistence.md`](09-data-and-persistence.md) | 数据库/缓存、为什么要有缓存、持久化 |
| 10 | [`10-reliability-security-observability.md`](10-reliability-security-observability.md) | 限流/熔断/优雅退出/指标/健康检查 |
| 11 | [`11-mastery-design-tradeoffs.md`](11-mastery-design-tradeoffs.md) | 精通：设计取舍、常见坑、如何扩展 |
| 99 | [`99-glossary-and-code-map.md`](99-glossary-and-code-map.md) | 术语表 + 代码地图（查文件用） |

## 一句话先给你定心丸

**服务器就是"一堆对象 + 一堆规则"搬到一台（或多台）机器上，由它持有唯一真相。**
客户端做的是"表现"，服务器做的是"权威"。你已有的 OO 思维**大部分能直接用**；
真正需要新学的是：**并发（同时处理很多玩家）、隔离（互不影响）、分布（一台不够用多台）**。

## 你需要的前置

- 会写代码（任意语言），懂 OO / 数据结构。
- 本机装好 Rust stable + （可选）Docker。见根目录 `README.md`。

## 建议的动手节奏

```bash
make run            # 跑起来一个单进程服务器（app/main.lua）
make test-lua       # 看集成测试怎么验证行为
make smoke          # 端到端冒烟
make bench          # 压测（感受"吞吐"）
make test-multinode # 两进程协作
```

读完 1–5 篇你就能看懂"服务怎么跑、请求怎么走"；
6–10 篇理解工程化；
11 篇是设计取舍，教你**自己判断该怎么拆**。

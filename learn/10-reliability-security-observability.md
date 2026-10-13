# 10 · 可靠性 / 安全 / 可观测

## 你将学到

服务器上线后，真正让你头疼的不是"功能"，而是：**被打爆、依赖挂了、崩了不知道、被作弊**。
这一篇讲三件事：怎么不崩、怎么安全、怎么"看得见"。

---

## 1. 可靠性（Reliability）：让它扛得住、挂得起

### (a) 限流（Rate Limit）
- **问题**：一个客户端疯狂发包 → 拖垮服务器。
- **做法**：每个连接/玩家限速（令牌桶）。超了就拒绝。
- 本仓库：`ccserver.ratelimit`，gateway 每连接限流，超限回 `ERROR "rate limited"`。

### (b) 熔断（Circuit Breaker）
- **问题**：下游服务挂了，你还拼命调它 → 雪上加霜。
- **做法**：连续失败达到阈值就"跳闸"，一段时间内**快速失败**，过一会再试探。
- 本仓库：`ccserver.breaker`，服务组每个实例一个熔断器。

### (c) 故障转移（Failover）
- **问题**：一个实例挂了，请求不能全挂。
- **做法**：同逻辑服务多实例，一个失败切下一个。
- 本仓库：`router` 服务组轮询 + failover。

### (d) 优雅退出（Graceful Shutdown / Drain）
- **问题**：直接杀进程，正在处理的请求全丢、玩家莫名掉线。
- **做法**：收到停机信号后：**停收新请求 → 处理完在途的 → 再关**。
- 本仓库：gateway 的 `on_stop` 做 drain（`docs/reliability.md`）。

### (e) 超时与重试
- 任何"等外部"的操作都要有**超时**，否则可能永远挂着。
- 重试要谨慎：**幂等**的读操作可重试；写操作重试可能重复扣钱，要幂等设计或去重。

## 2. 安全（Security）：不信任客户端

核心原则：**服务器权威，客户端说的话都要校验。**

| 威胁 | 对策 |
| --- | --- |
| 客户端改包/改内存 | 服务器自己算，只信服务器数据 |
| 明文密码 | 传输加密 + 存哈希（login 负责） |
| 密钥泄漏 | **密钥隔离**：只有 login 持密钥，别处不碰（`ccserver.secrets` + `redact` 日志） |
| 刷接口/重放 | 限流 + 请求序号 + token 时效 |
| 越权 | 每次操作校验"这个 uid 能不能做这件事" |

## 3. 可观测（Observability）：能看见，才修得好

服务器跑在黑盒里，你必须能"看到"它的状态。

### (a) 指标（Metrics）
- 计数/仪表/直方图：连接数、消息量、错误数、延迟。
- 本仓库：`ccserver.metrics`（Prometheus 格式），admin 服务 `/metrics`。

### (b) 健康检查（Health / Readiness）
- `/health`：进程还活着吗（存活探针）。
- `/ready`：能服务了吗（就绪探针，依赖都 OK）。
- 用于负载均衡/编排系统判断"要不要把流量给它"。
- 本仓库：`ccserver.health`，admin 服务 `/health` `/ready`。

### (c) 日志（Logging）
- 结构化日志 + 级别（ERROR/WARN/INFO/DEBUG）。
- **不要打印密钥/密码**。

### (d) 追踪（Tracing）
- 一个请求经过多个服务，用 **trace id** 串起来，方便排查。
- 本仓库：`ccserver.trace`，gateway 每个请求分配一个 id。

## 4. 为什么这三件事是"成熟"的分水岭

- **功能**能让服务器"跑起来"；**可靠性**让它在压力/故障下"不倒"；
  **可观测**让你在出问题时"知道为什么"；**安全**让它"不被玩坏"。
- 早期可以简化，但要**预留位置**——本仓库把它们都做成了可插拔模块。

## 5. 对应到代码

| 能力 | 文件 |
| --- | --- |
| 限流 | `lualib/ccserver/ratelimit.lua` |
| 熔断 | `lualib/ccserver/breaker.lua` |
| 优雅 drain | `lualib/ccserver/services/gateway.lua`（`on_stop`） |
| 密钥隔离 | `lualib/ccserver/secrets.lua` |
| 指标/健康/追踪 | `lualib/ccserver/{metrics,health,trace}.lua` |
| 运维端点 | `lualib/ccserver/services/admin.lua` |
| 备份校验 | `scripts/backup.sh` / `verify-backup.sh` |

---

## 动手

1. `make run` 后 `curl localhost:9002/metrics | head`，`curl localhost:9002/ready`。
2. `make test-reliability` 看限流/熔断测试。

## 记住这句

> **可靠 = 限流+熔断+故障转移+优雅退出；安全 = 不信任客户端+密钥隔离；可观测 = 指标+健康+日志+追踪。**

# 02 · 一个请求的完整旅程（启动 → 登录 → 进入 → 移动）

## 你将学到

服务器**从零启动到处理一次完整客户端请求**，中间每一步由谁执行、在哪个文件里。
**本篇文章会在流程里就地解释每个名词对应哪个代码对象**——读到哪、讲到哪，不用另找。

---

## 0. 先把名词对上"代码对象"（本篇会反复出现）

| 名词 | 代码里到底是什么 | 关键关系 |
| --- | --- | --- |
| **进程** | 一个 `moon_rs` 二进制实例（`ps` 里的一个进程） | 一个进程 = 一个**节点** |
| **节点 node** | 一个进程 + 一个整数 `node_id`；对应 `topology.nodes[node_id]` 那一项 | 节点里住着很多 **actor** |
| **actor** | 运行单元：一个整数 **actor id** + 独立 `lua_State` + 消息队列 | 一个 actor 跑一个**服务实例** |
| **服务 service** | 一个 Lua 脚本 + 一个逻辑名（如 `gateway.lua` / "gateway"） | 服务由 actor 来跑 |
| **实例 instance** | 一个**具体 actor**，名字唯一（如 "lobby_1"）；`moon.new_service` 创建并返回它的 id | 逻辑名 `lobby` 通过**组**指向多个实例 |
| **组 group** | 一张表 `{ lobby = {"lobby_1","lobby_2"} }` | 组 = 一组实例名，router 用它轮询 |
| **拓扑 topology** | 一个 Lua 表 `cfg`（`topology.load` 的返回值），含 `services`/`groups`/`nodes`/`cluster` 四段 | 决定"谁跑哪" |
| **router** | Lua 模块 `ccserver/router.lua`；**每个 actor 内各有一份配置**（node_id/services/groups） | 决定消息发本地还是远程 |
| **cluster** | 跨节点 RPC 子系统 = `lualib/moon/cluster.lua`（Lua 封装）+ `cluster.core`（Rust，**进程级全局**） | 不是服务，是"库 + 进程级状态"；router 远程调用时用它 |
| **discovery 发现** | 让节点互相找到地址：`cluster.init(node_id, discovery_url)` 里的 `discovery_url`（etcd 或 HTTP） | cluster 靠它解析"目标节点在哪" |
| **dispatch** | 每个 actor 的**消息处理回调**：`moon.dispatch("lua", fn)` | 别人发给你的消息，进这里处理 |

> 一句话记法：**进程=节点；节点住 actor；服务是职责、实例是具体 actor；组是实例名单；拓扑是配置表；router 是路由逻辑；cluster 是跨进程管道；discovery 是通讯录。**

---

## 阶段 A：进程启动（看清楚每一步创建了什么对象）

### A1. 你敲下命令

```bash
moon_rs app/main.lua 1        # 1 = 本节点 id
```

### A2. 引擎入口（Rust）

`crates/moon-app/src/main.rs`：

1. 启动 **Tokio 运行时**（网络/定时等异步任务的线程池）。
2. 装信号处理（Ctrl-C / SIGTERM）。
3. 初始化**日志**、**定时器/监视**。
4. 计算 `package.path`（让 Lua 能 `require` 到 `lualib/`）。
5. 加载并运行 `app/main.lua`——它以**第一个 actor** 的身份执行。

> **对象：** 到这里，进程里有了 **actor #1（名字 `bootstrap`）**。它就是"运行 main.lua 的那个 actor"。

### A3. 应用入口（Lua）

`app/main.lua`：

```lua
local cfg = topology.load("config/topology.lua")   -- 读拓扑
node.start(cfg, node_id)                            -- 按拓扑启动本节点
```

> **对象：** `cfg` 就是**拓扑**（一个 Lua 表）。它长这样：
> ```lua
> cfg = {
>   cluster  = { enabled=true, discovery_url="…", listen=false, etcd={…} },
>   services = { gateway={source="ccserver.services.gateway"}, world_1={…}, … },
>   groups   = { lobby = { "lobby_1", "lobby_2" } },
>   nodes    = { [1]={services={"gateway","login",…}}, [2]={services={"world_2"}} },
> }
> ```

### A4. 节点启动（框架）

`lualib/ccserver/node.lua` 的 `node.start(cfg, node_id)`，逐步：

1. **算本节点该起哪些服务**：
   `topology.for_node(cfg, node_id)` → `{ services = { {name="gateway",source=…}, … } }`。
   > 例如 node1 只拿到属于 node1 的那几项。

2. **（多节点时）初始化 cluster**：
   `cluster.init(node_id, cfg.cluster.discovery_url)` + `cluster.listen()`。
   > **对象：** `cluster` 不是服务，是一个**进程级全局状态**（Rust `cluster.core`）+ 一份 Lua 封装。
   > `init` 记下"我是几号节点、去哪查地址"；`listen` 绑一个 TCP 端口等别人连。
   > `cfg.cluster` 是它的**配置段**（enabled/discovery_url/listen/etcd），不是 cluster 本体。

3. **配置 router**：
   ```lua
   router.configure({
       node_id  = node_id,
       services = topology.service_nodes(cfg),  -- { gateway=1, world_1=1, world_2=2 }
       groups   = topology.groups(cfg),         -- { lobby={"lobby_1","lobby_2"} }
   })
   ```
   > **对象：** `router` 是 `ccserver/router.lua` 这个模块；`configure` 把上面两张表存进
   > **当前 actor 的 router 状态**。注意：**router 状态是 per-actor 的**（每个 actor 各存一份），
   > 而 `cluster` 是**进程级全局**的——这是后面"本地优先"的关键。

4. **逐个启动服务**：
   ```lua
   moon.new_service({ name="gateway", source="ccserver/services/gateway.lua",
                      unique=true, node=1, routing=services, groups=groups, config=… })
   ```
   > **对象：** 这一句**创建了一个 actor**，返回一个**整数 actor id**。
   > 参数里的 `name` 就是这个**实例名**（这里是 "gateway"；若是 `lobby_1` 则是 "lobby_1"）。
   > `source` 指向**服务脚本**（业务代码）。`routing`/`groups`/`node`/`config` 会被传进该 actor。

### A5. 服务脚本（每个服务 = 一个 actor）

gateway 脚本最后：

```lua
service.run({ name="gateway", commands={…}, on_start=…, on_stop=… }, ...)
```

`lualib/ccserver/service.lua` 的 `M.run` 做三件事：

1. `router.configure({ node_id=conf.node, services=conf.routing, groups=conf.groups })`
   ——**给这个 actor 自己的 router 装上路由表**。
2. `moon.dispatch("lua", handler)`——**安装这个 actor 的消息处理回调（dispatch）**。
3. 执行 `on_start`（gateway 在这里 `socket.listen("0.0.0.0:9001")`），并注册关闭处理。

> **对象：** 现在每个服务实例 = 一个 actor，actor 内有：
> - 自己的 `lua_State`（独立内存）；
> - 自己的 router 状态（路由表）；
> - 自己的 dispatch（消息入口）；
> - `self`（服务实例表，含 `name`/`node`/`config`）。

### 启动完成后的对象全景

```
进程 moon_rs（= 节点 node_id=1）
├── cluster：进程级全局（cluster.core）+ Lua 封装   ← 跨进程管道
│     discovery_url 指向"通讯录"（etcd/HTTP）
├── actor bootstrap   运行 main.lua（负责拉起所有服务）
├── actor "gateway"   实例；自带 router 表；dispatch；监听 9001
├── actor "login"     实例；自带 router 表；dispatch
├── actor "lobby_1"   实例；自带 router 表；dispatch
├── actor "world_1"   实例；自带 router 表；dispatch
└── actor "admin"     实例；HTTP 端点
```

---

## 阶段 B：一次客户端请求（每一步看"哪个 actor 在处理"）

### B1. 连接建立（gateway actor）

客户端 `connect(服务器:9001)`。引擎 accept 后，交给 **gateway actor** 的 `on_accept(fd, addr)`：

```lua
sessions[fd] = { fd=fd, addr=addr }   -- 连接归这个 gateway actor 私有
socket.start_read_frame(fd)
```

> **对象：** 连接（fd）是 gateway actor 的**私有状态**，别的 actor 看不到。

### B2. HELLO（版本协商）

客户端发一帧 → 引擎把它**作为一条消息投递给 gateway actor** → 触发它的 **dispatch**（`on_message`）：

```lua
local msg = protocol.decode(buffer.unpack(buf, "Z"))
-- msg = { version, type=REQUEST, msgid=HELLO, seq=1, args={version} }
```

> **对象：** 这就是"actor 收消息 → dispatch 处理"的具体体现。

### B3. LOGIN（鉴权，跨 actor）

```
gateway actor 的 handler LOGIN:
   router.call("login", "login", account, password)
        │  router 查表：services["login"] == 本节点 → 走【本地】moon.call
        ▼
   login actor 的 dispatch → commands.login → 生成 token
        │
        ◀── 返回 { uid, token }
   gateway 回 LOGIN_ACK 给客户端
```

> **名词落点：** gateway 用**自己 actor 的 router** 查到 login 在本节点 → **本地调用**（不走 cluster）。
> gateway 不校验密码，凭据转给 login；密钥只在 login。

### B4. ENTER（绑定会话 + 进入，可能跨进程）

```
gateway actor:
  1. router.call("login", "verify", token)          -- 本地
  2. 读共享会话(Redis)：uid 是否在别的网关？是→让那个网关踢线（顶号）
  3. 写共享会话：uid 的属主 = 本网关
  4. 本地若已有同 uid 连接 → 踢掉
  5. router.call("lobby", "enter", uid)
        │  "lobby" 是【组】→ router 轮询到 "lobby_1" 或 "lobby_2"（可能本地/远程）
  6. router.call("world_2", "enter", uid, zone)
        │  services["world_2"] 若在别的节点 → router 走【远程】cluster.call
  7. 回 ENTER_ACK
```

> **名词落点：**
> - `router` 对**组**做轮询（`groups.lobby`），对**普通名**查 `services` 映射。
> - **本地**（同节点）用 `moon.call`；**远程**（异节点）用 `cluster.call` —— 对业务代码完全透明。

### B5. MOVE（游戏内操作）

```
gateway actor:  handler MOVE → router.call(session.world, "move", uid, x, y)
world actor:    entities[uid].x, .y = x, y  → 返回 true
gateway:        回 MOVE_ACK
```

### 全链路一张图（标出名词）

```
client ──TCP──▶ [gateway actor]（实例 "gateway"）
   HELLO/LOGIN/ENTER/MOVE（协议帧）
        │ decode（protocol）
        ▼
   router.call(...)  ──本地 moon.call──▶ [login/lobby_1/world_1 actor]
        │             ──远程 cluster.call─▶ [另一个节点上的 world_2 actor]
        │                       （cluster 用 discovery 找到目标节点地址）
        ◀──────── 响应 ─────────┘
   encode + write_frame
client ◀──响应帧──
```

---

## 阶段 C：优雅关闭

收到 `SIGTERM`（`scripts/stop.sh`）：

1. 引擎向所有 actor 广播 shutdown 消息。
2. 每个 actor 的 `on_stop` 执行——gateway 会**优雅 drain**（停收新连接、等在途请求、关连接）。
3. actor 调 `moon.quit()`；进程结束。

---

## 名词之间到底是什么关系（一句话版）

```
进程 ──就是── 节点（一个 node_id）
节点 ──里面住着── 很多 actor
服务（职责） ──由── actor ──运行──
实例 ──就是── 一个具体 actor（有唯一 name）
组 ──是── 一组实例名（给 router 做轮询/failover）
拓扑（cfg 表） ──决定── 哪些实例跑在哪个节点 + 定义了哪些组
router（每个 actor 内一份） ──用拓扑派生的两张表── 决定消息发本地还是远程
cluster（进程级） ──是── 远程调用走的管道；靠 discovery 找目标节点地址
dispatch ──是── 每个 actor 收消息的入口
```

---

## 动手

1. `make run`，另开终端 `curl localhost:9002/ready`。
2. 对照 `lualib/ccserver/node.lua`，找到 `topology.for_node`、`router.configure`、`moon.new_service`。
3. 对照 `lualib/ccserver/service.lua` 的 `M.run`，找到 `moon.dispatch` 和 `router.configure`。
4. 跑 `make smoke`，看它自动完成"连接→登录→进入→移动"。

## 记住这句

> **进程=节点；节点住 actor；服务是职责、实例是具体 actor；组是实例名单；拓扑是配置表；
> router 是每个 actor 内的路由逻辑；cluster 是跨进程管道；discovery 是通讯录；dispatch 是消息入口。**

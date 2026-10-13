# 02 · 一个请求的完整旅程（启动 → 登录 → 进入 → 移动）

## 你将学到

服务器**从零启动到处理一次完整客户端请求**，中间每一步由谁执行、在哪个文件里。这是理解全局的骨架。

---

## 阶段 A：进程启动

### A1. 你敲下命令

```bash
moon_rs app/main.lua 1        # 1 = 本节点 id
```

### A2. 引擎入口（Rust）

`crates/moon-app/src/main.rs` 做初始化：

1. 启动 **Tokio 异步运行时**（管理网络/定时器等）。
2. 设置信号处理（Ctrl-C / SIGTERM）。
3. 初始化**日志**、**定时器/监视**。
4. 计算 `package.path`（让 Lua 能 `require` 到 `lualib/`）。
5. **加载并运行 `app/main.lua`**——它以第一个 actor（名字 `bootstrap`）的身份执行。

> 此时进程里已经有一个 actor 在跑 Lua 了。

### A3. 应用入口（Lua）

`app/main.lua`：

```lua
local cfg = topology.load("config/topology.lua")   -- 读"服务安置图"
node.start(cfg, node_id)                            -- 按图启动本节点
```

### A4. 节点启动（框架）

`lualib/ccserver/node.lua` 的 `node.start`：

1. 按拓扑算出**本节点该起哪些服务**（`topology.for_node`）。
2. （多节点时）`cluster.init(node_id, discovery_url)` + `cluster.listen()`，
   并把自己的地址注册到 etcd。
3. `router.configure{ node_id, services=服务→节点, groups=组→实例 }`——**告诉路由：谁在哪**。
4. 对每个服务：`moon.new_service({name, source, ...})`
   → 引擎**创建一个 actor**，执行该服务脚本。

### A5. 服务脚本（每个服务一个 actor）

以 gateway 为例，`lualib/ccserver/services/gateway.lua` 最后调用：

```lua
service.run({ name="gateway", commands={...}, on_start=..., on_stop=... }, ...)
```

`service.run`（`lualib/ccserver/service.lua`）做三件事：

1. `moon.dispatch("lua", handler)`——**安装这个 actor 的消息处理回调**。
2. 执行 `on_start`——gateway 在这里 `socket.listen("0.0.0.0:9001")`，**开始监听客户端**。
3. 注册关闭处理（`moon.shutdown`）。

**启动完成**：进程内有了 `bootstrap` + `gateway` + `login` + `lobby` + `world` + `admin`
等 actor，gateway 已在 9001 端口监听。

```
进程（单进程多线程）
├── actor bootstrap   运行 main.lua（负责拉起所有服务）
├── actor gateway     监听 9001，持有所有客户端连接
├── actor login       鉴权
├── actor lobby       社交/匹配
├── actor world       实体/位置
└── actor admin       可观测 HTTP 端点
```

---

## 阶段 B：一次客户端请求

假设客户端要做：**握手 → 登录 → 进入游戏 → 移动**。

### B1. 连接建立

客户端 `connect(服务器:9001)`。
引擎 accept 这个 TCP 连接，把 fd 交给 gateway actor 的 `on_accept(fd, addr)`：

```lua
sessions[fd] = { fd=fd, addr=addr }   -- 记住这个连接
socket.start_read_frame(fd)           -- 开启"按帧自动读取"
```

> 连接的所有权属于 gateway actor。**客户端连接不是全局的，是挂在某个 gateway 上的。**

### B2. HELLO（版本协商）

客户端发一帧。引擎读到一帧，**作为一条消息投递给 gateway actor**，
触发 `on_message(fd, buf)`：

```lua
local msg = protocol.decode(buffer.unpack(buf, "Z"))
-- msg = { version, type=REQUEST, msgid=HELLO, seq=1, args={version} }
```

gateway 检查版本，回 `HELLO_ACK`，并记住 `session.ver`。

### B3. LOGIN（鉴权）

客户端发 `LOGIN(account, password)`：

```
gateway actor:
  handler LOGIN → router.call("login", "login", account, password)
                     │
                     ▼  router 查表：login 在本节点 → 本地 moon.call
  login actor:  dispatch → commands.login → 生成 token
                     │
                     ◀── 返回 { uid, token }
  gateway: 回 LOGIN_ACK { uid, token } 给客户端
```

**注意**：gateway 自己**不校验密码**，它只是把凭据转给 login。密码/密钥只存在 login。

### B4. ENTER（绑定会话 + 进入游戏）

客户端发 `ENTER(token, zone)`：

```
gateway actor:
  1. router.call("login", "verify", token)     -- 校验 token 得到 uid
  2. 读共享会话(Redis)：uid 是否在别的网关登录？是→让那个网关踢线（顶号）
  3. 写共享会话：uid 的属主 = 本网关
  4. 本地若已有同 uid 连接 → 踢掉
  5. router.call("lobby", "enter", uid)        -- 进入大厅
  6. router.call("world_N", "enter", uid, zone)-- 进入对应世界分片
  7. 回 ENTER_ACK { uid, zone, lobby, world }
```

### B5. MOVE（游戏内操作）

客户端发 `MOVE(x, y)`：

```
gateway actor:
  handler MOVE → router.call(session.world, "move", uid, x, y)
  world actor:  entities[uid].x, .y = x, y ; 返回 true
  gateway: 回 MOVE_ACK
```

### 全链路一张图

```
client ──TCP──▶ [gateway actor]
   HELLO/LOGIN/ENTER/MOVE (协议帧)
        │ decode
        ▼
   router.call(...)   ──本地──▶ [login/lobby/world actor] ── 改状态/返回
        │                              │
        ◀──────── 响应 ───────────────┘
   encode + write_frame
client ◀──响应帧──
```

---

## 阶段 C：优雅关闭

收到 `SIGTERM`（`scripts/stop.sh`）：

1. 引擎向所有 actor 广播 shutdown 消息。
2. 每个 actor 的 `on_stop` 执行——gateway 会**优雅 drain**（停收新连接、等在途请求、关连接）。
3. actor 调 `moon.quit()` 退出；进程结束。

---

## 为什么要这样设计？（先有个印象）

- **分阶段、职责单一**：入口→节点→服务，每层只干一件事。
- **连接归 gateway、鉴权归 login、状态归 world**：各管各的，互不越界。
- **一切通过消息**：gateway 不直接改 world 的数据，而是"请求 world 去改"。
- **路由透明**：`router.call("login", ...)` 不关心 login 在哪台机器——本地就本地调，异地就跨进程。

---

## 动手

1. `make run`，另开终端 `curl localhost:9002/ready`，看服务器在跑。
2. 对照 `lualib/ccserver/services/gateway.lua`，找到 `on_accept / on_message / handlers.LOGIN / handlers.ENTER / handlers.MOVE`。
3. 跑 `make smoke`，看它如何自动完成"连接→登录→进入→移动"。

## 记住这句

> **启动：入口 → 拓扑 → 每个服务变成一个 actor。请求：客户端帧 → gateway actor → router → 目标 actor → 回包。**

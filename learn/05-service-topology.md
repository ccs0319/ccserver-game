# 05 · 服务拆分与拓扑

## 你将学到

为什么不能把所有逻辑塞进一个大程序，而要拆成 gateway/login/lobby/world；"拓扑"到底解决了什么问题。

---

## 1. 先想一个问题：为什么不一锅端？

最省事的做法：一个程序里塞下所有功能（登录、战斗、背包、聊天…）。
**小项目、早期、人少时，这没错。** 但规模一上来就痛：

| 问题 | 一锅端的后果 |
| --- | --- |
| **伸缩** | 登录是"突发短连接"，战斗是"稳态长连接"，混在一起没法各自扩容 |
| **故障** | 战斗代码崩了，把登录一起带走 |
| **安全** | 鉴权密钥和战斗逻辑同处一室，面变大 |
| **发布** | 改一个玩法要重启整个服务器，全员掉线 |

所以成熟做法是**按职责拆服务**，每个服务独立部署、独立伸缩、独立发布。

## 2. 本框架的拆分

| 服务 | 职责 | 为什么独立 |
| --- | --- | --- |
| **gateway** | 客户端连接、协议、会话绑定 | 连接无状态，可水平扩；是"对外唯一入口" |
| **login** | 账号鉴权、发 token | 安全敏感，**唯一持有密钥**；可独立扩 |
| **lobby** | 社交/匹配/聊天 | 大体无状态，可多实例 |
| **world** | 游戏内状态（实体/AOI） | **有状态**，需按区/线**分片** |
| **admin** | 运维端点（指标/健康） | 运维关注点分离 |

**拆分的判断标准**（记住这四条）：
1. **伸缩特征不同**（突发 vs 稳态）→ 拆。
2. **故障域不同**（一个崩别拖垮全部）→ 拆。
3. **发布节奏不同**（玩法常改，鉴权少改）→ 拆。
4. **安全边界不同**（密钥别扩散）→ 拆。

> 反过来：**职责相同、伸缩一致的就别拆**。拆太细会带来跨服务调用开销和复杂度。

## 3. 拓扑：部署蓝图

拓扑 = **一张表**，规定"哪个服务跑在哪台机器（进程）上"。

```lua
-- app/config/topology.lua
services = {                    -- 有哪些服务、代码在哪
  gateway = { source = "ccserver.services.gateway" },
  login   = { source = "ccserver.services.login" },
  lobby_1 = { source = "ccserver.services.lobby" },
  lobby_2 = { source = "ccserver.services.lobby" },
  world_1 = { source = "ccserver.services.world", config = { zone = 1 } },
  world_2 = { source = "ccserver.services.world", config = { zone = 2 } },
}
groups = { lobby = { "lobby_1", "lobby_2" } }   -- 多实例：轮询+故障转移
nodes = {                        -- 安置表
  [1] = { services = { "gateway", "login", "lobby_1", "lobby_2", "world_1" } },
  [2] = { services = { "world_2" } },           -- 把这行打开 = 多进程
}
```

- **服务目录**：有哪些服务、代码在哪。
- **分组**：同一逻辑服务的多个实例（`lobby_1/lobby_2`），可轮询、可故障转移。
- **安置表**：哪个服务在哪个节点。

## 4. 关键：业务代码不关心拓扑

服务之间用**逻辑名**调用：

```lua
router.call("login", "verify", token)     -- 不写 IP、不写节点号
router.call("world_2", "move", uid, x, y)
```

`router` 查拓扑的"服务→节点"映射：
- 目标在本节点 → **本地调用**（`moon.call`，不走网络）。
- 目标在别的节点 → **跨进程调用**（`cluster.call`，走 TCP）。

**所以：同一份业务代码，改拓扑就能从"单进程"变"多进程"。**

## 5. 三种部署形态（同一套代码）

```
单机全塞              单机分片                多节点
─────────            ─────────              ─────────
node1:               node1:                 node1: gateway/login/lobby/world_1
 gateway              gateway                node2: world_2
 login                login                  (cluster 互联 + 发现)
 lobby                lobby
 world                world_1, world_2
```

## 6. 一个新手最容易犯的错

**把状态放错地方。** 记住：

- **无状态**（gateway/lobby 大部分逻辑）→ 可随意多实例、随便扩容。
- **有状态**（world 的实体）→ 必须"谁拥有谁负责"，且要分片；跨服务不能直接读它的内存，只能发消息。
- **需要跨服务共享的状态**（会话）→ 外置到 Redis（第 7 篇）。

---

## 动手

1. 读 `app/config/topology.lua` 和 `app/config/topology.multinode.lua`，对比两行 `nodes`。
2. 跑 `make test-multinode`，感受"同一份代码，拓扑一改就跨进程"。

## 记住这句

> **按伸缩/故障/发布/安全四条标准拆服务；拓扑是"谁跑哪"的蓝图；业务代码只认逻辑名，拆分是配置。**

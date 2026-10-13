# 06 · 消息与协议

## 你将学到

服务器里"调用"是怎么变成"发消息"的；内部消息和对外协议有什么不同；为什么要有序列化、版本号、请求序号。

---

## 1. 两种"消息"，别搞混

| | 内部消息 | 对外协议 |
| --- | --- | --- |
| 谁和谁 | 服务 ↔ 服务（gateway↔login↔world） | 客户端 ↔ 服务器（gateway） |
| 例子 | `router.call("login","verify",token)` | 客户端发 `LOGIN` 帧 |
| 代码 | `moon.send/call`、`cluster` | `ccserver.protocol` |
| 传输 | 同进程内存 / 跨进程 TCP | 客户端 TCP |

两者本质一样：**把"调用"变成"发一条带数据的消息"。**

## 2. 为什么用消息，而不是直接调用

- 服务之间**不共享内存**（第 3、4 篇）。直接 `login.verify(token)` 会跨线程读写别人的内存 → 危险。
- 发消息则天然安全：**你只把数据递给对方，对方自己处理自己的内存。**
- 而且消息可以**跨进程**：本地调用和远程调用是同一套写法（`router.call`）。

## 3. 两种发送方式：send 与 call

| 方式 | 语义 | 用在哪 |
| --- | --- | --- |
| **send**（通知） | 发出去就不管，不等回复 | 广播、事件、日志 |
| **call**（请求/响应） | 发出去后**等对方回复** | 需要结果（查数据、验证 token） |

`call` 的"等"是**挂起当前协程**（第 3 篇），线程去服务别人：

```lua
local auth = router.call("login", "verify", token)   -- 挂起，等 login 回
-- 这里拿到结果，继续
```

## 4. 序列化：把值变成字节

本地调用可以直接传对象指针；**跨进程不行**，得把值"打包成字节"再发，对方"拆包"还原。

```
{ uid=1, name="Alice" }  ──打包(seri)──▶  "…bytes…"  ──网络──▶  ──拆包──▶  { uid=1, name="Alice" }
```

本仓库默认用 **`seri`**（引擎自带的二进制序列化）。对外的 payload 也可以换成 **protobuf**。

> 为什么重要：序列化决定了"能传什么、多大、多快"。简单值随便传；
> 复杂对象要考虑"传不传得下、要不要压缩"。

## 5. 对外协议：给字节定格式

客户端和服务器必须先约定"这一串字节是什么意思"。本仓库的帧格式：

```
传输帧:  [2字节长度][body]          ← 引擎的 socket 帧协议负责
body:    [version][type][msgid][seq][payload]   ← ccserver.protocol 负责
```

| 字段 | 作用 |
| --- | --- |
| `version` | 协议版本。不匹配就拒绝，**让协议演进变得显式** |
| `type` | REQUEST / RESPONSE / NOTIFY |
| `msgid` | 消息编号（HELLO=1, LOGIN=10, MOVE=14…） |
| `seq` | 客户端自增序号，**用来把响应和请求对上** |
| `payload` | 真正的数据（序列化后的值） |

## 6. 为什么要 seq（请求序号）

客户端可能**并发**发多个请求，响应回来的顺序不保证。
`seq` 让客户端知道"这个响应是回哪条请求的"：

```
客户端发: LOGIN(seq=1)  MOVE(seq=2)
服务器回: RESP(seq=2)   RESP(seq=1)   ← 顺序可能乱
客户端按 seq 匹配，不会张冠李戴
```

## 7. 版本协商（握手）

客户端第一件事发 `HELLO(版本号)`，服务器比对：
- 一致 → 回 `HELLO_ACK`，开始正常通信。
- 不一致 → 回错误并断开。

好处：**协议升级不会静默错乱**——老客户端连新服务器会被明确拒绝，而不是"发出奇怪的数据"。

## 8. 错误约定：永不"悬挂"

一次 `call` 如果对方出错却不回，调用方会**永远等下去**。所以约定：

- 成功：回结果值。
- 失败：回 `(false, 错误信息)`。

本仓库的 `service.lua` 自动把处理器异常转成 `(false, err)`，`protocol` 对未知消息回 `ERROR`。
**这样调用方总能拿到结果，不会卡死。**

## 9. 对应到代码

| 概念 | 文件 |
| --- | --- |
| 对外帧格式 | `lualib/ccserver/protocol.lua` |
| 内部 send/call | `lualib/moon.lua`（`moon.send`/`moon.call`） |
| 跨进程 send/call | `lualib/moon/cluster.lua` |
| 路由（决定本地/远程） | `lualib/ccserver/router.lua` |

---

## 动手

1. 打开 `assets/test/test_gateway.lua`，看客户端如何组帧、发 HELLO/LOGIN/ENTER、按 seq 等响应。
2. 打开 `lualib/ccserver/protocol.lua`，看 `encode/decode` 和消息表 `MSG`。

## 记住这句

> **一切皆消息：send（不等）/ call（等）；跨进程要序列化；对外协议有版本+序号；错误回 `(false,err)` 永不悬挂。**

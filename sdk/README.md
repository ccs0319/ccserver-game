# ccsclient — 跨平台客户端协议库

`ccsclient` 是 **ccserver 的客户端底层库**：只做**协议帧 + 编解码**，不涉及具体游戏消息。
**网络传输由宿主提供**（各平台不同）。

- 目标平台：macOS / Windows(x86,x64) / iOS(arm64) / Android(arm64) / 微信小游戏(WebAssembly)。
- 关键约束：**微信小游戏只能用它自己的网络 API**（`wx.connectSocket`），**WASM 不能直接开 socket**；
  因此 WASM 只负责编解码，**JS 侧持有 socket**，把收到的字节喂给库、把库产出的字节发出去。

## 协议格式（与服务器 `lualib/ccserver/protocol.lua` 一致）

```
frame = [len: u16 BE][body]           len == 0xFFFF 表示还有后续分片
body  = [version: u8][type: u8][msgid: u16 BE][seq: u32 BE][payload...]
```

- `payload` 对库是**不透明字节**：由你决定编码（JSON / protobuf / 自定义），库不管内容。
- `type`：REQUEST=1 / RESPONSE=2 / NOTIFY=3；`version` 当前 = 1。

> 注意：服务器当前 payload 用的是 `seri`。客户端要么用 seri，要么把服务器 payload 换成
> 客户端也支持的编码（JSON/protobuf）——框架的 payload 编解码是可替换的。

## 原生（macOS / Windows / iOS / Android）

```rust
use ccsclient::{Client, native::TcpTransport};
use std::time::Duration;

let tcp = TcpTransport::connect("game.example.com:9001", Duration::from_secs(10))?;
let mut client = Client::new(tcp);

client.hello()?;                       // HELLO 握手
let seq = client.request(10, payload)?; // 例如 LOGIN，payload 由你编码

let mut buf = [0u8; 8192];
loop {
    let n = client.transport_mut().read(&mut buf)?;
    for msg in client.recv(&buf[..n]) {
        // 按 msgid / seq 分发；msg.payload 由你解码
    }
}
```

构建：

```bash
cargo build --release --features native                 # 本机
cargo build --release --target aarch64-apple-ios        # iOS
cargo build --release --target aarch64-linux-android    # Android
cargo build --release --target x86_64-pc-windows-msvc   # Windows
```

产物是 `cdylib`/`staticlib`，可通过 JNI / Swift / C ABI 暴露给各平台原生层。

## 微信小游戏（WASM + JS 持有 socket）

WASM 只导出编解码，网络走 `wx.connectSocket`：

```bash
cargo build --release --target wasm32-unknown-unknown --features wasm
# 用 wasm-bindgen 生成 JS 绑定，产物放进小游戏代码包
wasm-bindgen --target web --out-dir dist target/wasm32-unknown-unknown/release/ccsclient.wasm
```

JS 侧（参考 `examples/wechat.js`）：

```js
import init, { version, encode_request, Decoder } from './dist/ccsclient.js';
await init();

const dec = new Decoder();
const socket = wx.connectSocket({ url: 'wss://game.example.com/ws' });

socket.onMessage((res) => {
  const bytes = new Uint8Array(res.data);
  for (const m of dec.push(bytes)) {
    // m = { version, type, msgid, seq, payload: Uint8Array }
  }
});

function sendRequest(msgid, seq, payloadBytes) {
  const frame = encode_request(msgid, seq, payloadBytes); // Uint8Array
  socket.send({ data: frame.buffer });
}
```

**微信限制（务必遵守）**：
- 必须在**小游戏后台配置合法域名**（`wss://`，不能是 IP/localhost；局域网 IP 除外）。
- `wx.connectSocket` 最多 **5 个**并发连接。
- 网络请求有超时（默认 60s，可在 `game.json` 配 `networkTimeout`）。

## 目录

```
sdk/ccsclient/
  Cargo.toml
  src/lib.rs       # 帧 + 编解码（纯逻辑，无网络）
  src/client.rs    # Transport trait + Client（seq/握手）
  src/native.rs    # 原生 TCP 传输（feature = native）
  src/wasm.rs      # WASM 导出（feature = wasm）
  examples/wechat.js
```

## 测试

```bash
cd sdk/ccsclient && cargo test
```

## 后续可扩展

- 载荷编解码：内置 JSON（serde）或 protobuf 帮助函数（当前留作不透明字节）。
- KCP/WebSocket 原生传输（当前示例为 TCP）。
- 重连/心跳/断线重发策略封装（当前只到协议层）。

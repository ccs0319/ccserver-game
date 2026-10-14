// WeChat mini-game glue for ccsclient (WASM).
//
// Build:
//   cargo build --release --target wasm32-unknown-unknown --features wasm
//   wasm-bindgen --target web --out-dir dist \
//     target/wasm32-unknown-unknown/release/ccsclient.wasm
//
// WeChat cannot use raw sockets from WASM: the JS side owns the socket via
// wx.connectSocket and only uses the WASM module for encode/decode.

import init, { version, encode_request, Decoder } from './dist/ccsclient.js';

let decoder;
let socket;
let seq = 1;
const pending = new Map(); // seq -> { resolve, reject }

export async function connect(url) {
  await init();
  console.log('ccsclient protocol version', version());

  decoder = new Decoder();
  socket = wx.connectSocket({ url });

  socket.onOpen(() => {
    // HELLO handshake (msgid = 1)
    sendRequest(1, new Uint8Array([version()]));
  });

  socket.onMessage((res) => {
    const bytes = res.data instanceof ArrayBuffer ? new Uint8Array(res.data) : res.data;
    for (const m of decoder.push(bytes)) {
      const p = pending.get(m.seq);
      if (p) {
        pending.delete(m.seq);
        p.resolve(m);
      } else {
        // unsolicited / notify
        onNotify(m);
      }
    }
  });

  socket.onError((e) => console.error('socket error', e));
  socket.onClose((e) => console.warn('socket closed', e));
}

// Send a REQUEST and await its RESPONSE (matched by seq).
export function request(msgid, payloadBytes) {
  return new Promise((resolve, reject) => {
    const mySeq = seq++;
    pending.set(mySeq, { resolve, reject });
    sendRequest(msgid, payloadBytes, mySeq);
  });
}

function sendRequest(msgid, payloadBytes, mySeq = seq++) {
  const frame = encode_request(msgid, mySeq, payloadBytes || new Uint8Array());
  socket.send({ data: frame.buffer });
  return mySeq;
}

function onNotify(_msg) {
  // handle server-initiated messages (e.g. KICK)
}

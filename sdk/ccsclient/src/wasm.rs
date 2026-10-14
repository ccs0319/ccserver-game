//! WebAssembly exports for hosts that own the socket.
//!
//! Enabled with `feature = "wasm"`. WASM cannot open sockets, so in a WeChat
//! mini-game (or browser) the **JS side** owns the connection via
//! `wx.connectSocket` and:
//!
//! * calls [`encode_request`] to build bytes, then `socketTask.send(...)`;
//! * feeds received bytes to [`Decoder::push`], which returns decoded messages.
//!
//! See `sdk/README.md` for the JS glue.

use wasm_bindgen::prelude::*;

use js_sys::{Array, Object, Reflect, Uint8Array};

use crate::{decode_body, encode, Framer, Message, VERSION};

/// Protocol version understood by this build.
#[wasm_bindgen]
pub fn version() -> u8 {
    VERSION
}

/// Encode a REQUEST into framed bytes (send via the host socket).
#[wasm_bindgen]
pub fn encode_request(msgid: u16, seq: u32, payload: &[u8]) -> Vec<u8> {
    encode(&Message::request_with(msgid, seq, payload.to_vec()))
}

/// Streaming decoder. Feed inbound socket bytes; get message objects back.
#[wasm_bindgen]
pub struct Decoder {
    framer: Framer,
}

#[wasm_bindgen]
impl Decoder {
    #[wasm_bindgen(constructor)]
    pub fn new() -> Decoder {
        Decoder { framer: Framer::new() }
    }

    /// Feed bytes from the host socket.
    ///
    /// Returns a JS array of `{ version, type, msgid, seq, payload: Uint8Array }`.
    pub fn push(&mut self, data: &[u8]) -> Array {
        let out = Array::new();
        for body in self.framer.feed(data) {
            if let Some(m) = decode_body(&body) {
                let o = Object::new();
                let _ = Reflect::set(&o, &JsValue::from_str("version"), &JsValue::from_f64(m.version as f64));
                let _ = Reflect::set(&o, &JsValue::from_str("type"), &JsValue::from_f64(m.mtype as f64));
                let _ = Reflect::set(&o, &JsValue::from_str("msgid"), &JsValue::from_f64(m.msgid as f64));
                let _ = Reflect::set(&o, &JsValue::from_str("seq"), &JsValue::from_f64(m.seq as f64));
                let payload = Uint8Array::from(m.payload.as_slice());
                let _ = Reflect::set(&o, &JsValue::from_str("payload"), &payload);
                out.push(&o);
            }
        }
        out
    }
}

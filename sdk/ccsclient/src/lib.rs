//! `ccsclient` — cross-platform client protocol library for **ccserver**.
//!
//! This crate does **protocol framing + codec only** (no game-message semantics):
//! it turns bytes from the server into messages and messages into bytes. The
//! **transport is provided by the host**, because the platforms differ:
//!
//! * **Native** (macOS / Windows / iOS / Android): use the built-in TCP
//!   transport (`feature = "native"`).
//! * **WeChat mini-game / browser (WASM)**: WASM cannot open sockets; the host
//!   (JS) owns the socket via `wx.connectSocket` and feeds bytes to this library
//!   (`feature = "wasm"` exports `encode`/`Decoder`). See `sdk/README.md`.
//!
//! Wire format (matches the server's `lualib/ccserver/protocol.lua`):
//!
//! ```text
//! frame  = [len: u16 BE][body]                 (len == 0xFFFF => more chunks follow)
//! body   = [version: u8][type: u8][msgid: u16 BE][seq: u32 BE][payload...]
//! ```
//!
//! `payload` is opaque to this library — the host chooses its own encoding
//! (JSON, protobuf, …) and just hands over bytes.

#![cfg_attr(not(feature = "std"), no_std)]

extern crate alloc;

use alloc::vec::Vec;

pub mod client;
pub mod codec;
#[cfg(feature = "native")]
pub mod native;
#[cfg(feature = "wasm")]
pub mod wasm;

/// Protocol version understood by this library.
pub const VERSION: u8 = 1;

/// Message types (body `type` field).
pub mod msg_type {
    pub const REQUEST: u8 = 1;
    pub const RESPONSE: u8 = 2;
    pub const NOTIFY: u8 = 3;
}

/// Header size in bytes: version(1) + type(1) + msgid(2) + seq(4).
pub const HEADER_SIZE: usize = 8;

/// Max body length carried by one frame (0xFFFF marks a continuation chunk).
pub const MAX_CHUNK: usize = 0xFFFF;

/// A decoded protocol message. `payload` is opaque bytes chosen by the host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub version: u8,
    pub mtype: u8,
    pub msgid: u16,
    pub seq: u32,
    pub payload: Vec<u8>,
}

impl Message {
    /// Build a request message with an empty payload.
    pub fn request(msgid: u16, seq: u32) -> Self {
        Message { version: VERSION, mtype: msg_type::REQUEST, msgid, seq, payload: Vec::new() }
    }

    /// Build a request message with a payload.
    pub fn request_with(msgid: u16, seq: u32, payload: Vec<u8>) -> Self {
        Message { version: VERSION, mtype: msg_type::REQUEST, msgid, seq, payload }
    }
}

/// Encode a message body (header + payload), without the length framing.
pub fn encode_body(msg: &Message) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_SIZE + msg.payload.len());
    out.push(msg.version);
    out.push(msg.mtype);
    out.extend_from_slice(&msg.msgid.to_be_bytes());
    out.extend_from_slice(&msg.seq.to_be_bytes());
    out.extend_from_slice(&msg.payload);
    out
}

/// Encode a full frame: `[len: u16 BE][body]`, chunking bodies larger than
/// `MAX_CHUNK` exactly like the server (all but the last chunk carry `0xFFFF`).
pub fn encode_frame(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len() + 2 + body.len() / MAX_CHUNK * 2);
    if body.is_empty() {
        out.extend_from_slice(&0u16.to_be_bytes());
        return out;
    }
    let mut offset = 0usize;
    while offset < body.len() {
        let remaining = body.len() - offset;
        let take = remaining.min(MAX_CHUNK);
        let more = remaining > MAX_CHUNK;
        let len = if more { MAX_CHUNK as u16 } else { take as u16 };
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(&body[offset..offset + take]);
        offset += take;
    }
    out
}

/// Decode a single body (header + payload) into a [`Message`].
pub fn decode_body(body: &[u8]) -> Option<Message> {
    if body.len() < HEADER_SIZE {
        return None;
    }
    let version = body[0];
    let mtype = body[1];
    let msgid = u16::from_be_bytes([body[2], body[3]]);
    let seq = u32::from_be_bytes([body[4], body[5], body[6], body[7]]);
    Some(Message { version, mtype, msgid, seq, payload: body[HEADER_SIZE..].to_vec() })
}

/// Encode a message straight to a framed byte stream.
pub fn encode(msg: &Message) -> Vec<u8> {
    encode_frame(&encode_body(msg))
}

/// Streaming frame decoder: feed bytes, get complete bodies back. Reassembles
/// `0xFFFF` continuation chunks into one body.
#[derive(Default)]
pub struct Framer {
    buf: Vec<u8>,
    acc: Vec<u8>,
}

impl Framer {
    pub fn new() -> Self {
        Framer::default()
    }

    /// Feed a chunk of bytes; returns any complete bodies now available.
    pub fn feed(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.buf.extend_from_slice(data);
        let mut out = Vec::new();
        loop {
            if self.buf.len() < 2 {
                break;
            }
            let len = u16::from_be_bytes([self.buf[0], self.buf[1]]) as usize;
            if self.buf.len() < 2 + len {
                break;
            }
            let chunk = self.buf[2..2 + len].to_vec();
            self.buf.drain(0..2 + len);
            self.acc.extend_from_slice(&chunk);
            if len < MAX_CHUNK {
                out.push(core::mem::take(&mut self.acc));
            }
        }
        out
    }
}

/// Convenience: decode a full framed byte stream into messages.
pub fn decode_all(data: &[u8]) -> Vec<Message> {
    let mut framer = Framer::new();
    framer.feed(data).into_iter().filter_map(|b| decode_body(&b)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_small() {
        let msg = Message::request_with(10, 7, b"hello".to_vec());
        let bytes = encode(&msg);
        assert_eq!(bytes.len(), 2 + HEADER_SIZE + 5);
        let got = decode_all(&bytes);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0], msg);
    }

    #[test]
    fn header_layout() {
        let msg = Message::request(14, 0x01020304);
        let body = encode_body(&msg);
        assert_eq!(&body[..2], &[1, 1]); // version=1, type=REQUEST
        assert_eq!(&body[2..4], &[0, 14]); // msgid BE
        assert_eq!(&body[4..8], &[1, 2, 3, 4]); // seq BE
    }

    #[test]
    fn reassembles_chunks() {
        let big = vec![7u8; MAX_CHUNK * 2 + 10];
        let msg = Message::request_with(1, 1, big.clone());
        let framed = encode(&msg);
        // split into awkward pieces to exercise the streaming decoder
        let mut framer = Framer::new();
        let mut bodies = Vec::new();
        for chunk in framed.chunks(1000) {
            bodies.extend(framer.feed(chunk));
        }
        assert_eq!(bodies.len(), 1);
        let decoded = decode_body(&bodies[0]).unwrap();
        assert_eq!(decoded.payload, big);
    }

    #[test]
    fn partial_header_waits() {
        let msg = Message::request(1, 1);
        let framed = encode(&msg);
        let mut framer = Framer::new();
        assert!(framer.feed(&framed[..1]).is_empty());
        assert_eq!(framer.feed(&framed[1..]).len(), 1);
    }
}

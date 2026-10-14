//! Transport-agnostic client: sequence management + framing over a host-provided
//! transport. The host decides *how* bytes move (native TCP, native WebSocket,
//! `wx.connectSocket` in a WeChat mini-game, a test harness, …).
//!
//! Two framing modes:
//! * [`Framing::Tcp`] — the stream carries `[len][body]` frames (TCP transport).
//! * [`Framing::Message`] — each transport message is one body (WebSocket, where
//!   the WS layer already delimits messages).

use alloc::string::String;
use alloc::vec::Vec;

use crate::{decode_body, encode_body, encode_frame, Framer, Message};

/// Errors surfaced by the transport layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError(pub String);

/// Something that can send bytes to the server. The host implements this.
pub trait Transport {
    fn write(&mut self, data: &[u8]) -> Result<(), TransportError>;
}

/// How messages are delimited on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Framing {
    /// Length-prefixed stream framing (TCP).
    Tcp,
    /// One body per transport message (WebSocket).
    Message,
}

/// A minimal protocol client.
pub struct Client<T: Transport> {
    transport: T,
    framer: Framer,
    next_seq: u32,
    framing: Framing,
}

impl<T: Transport> Client<T> {
    /// Client over a length-framed stream (TCP).
    pub fn new(transport: T) -> Self {
        Client { transport, framer: Framer::new(), next_seq: 1, framing: Framing::Tcp }
    }

    /// Client over a message-oriented transport (WebSocket): one body per message.
    pub fn new_message(transport: T) -> Self {
        Client { transport, framer: Framer::new(), next_seq: 1, framing: Framing::Message }
    }

    pub fn transport(&self) -> &T {
        &self.transport
    }

    pub fn transport_mut(&mut self) -> &mut T {
        &mut self.transport
    }

    pub fn framing(&self) -> Framing {
        self.framing
    }

    fn write_msg(&mut self, msg: &Message) -> Result<(), TransportError> {
        let body = encode_body(msg);
        let bytes = match self.framing {
            Framing::Tcp => encode_frame(&body),
            Framing::Message => body,
        };
        self.transport.write(&bytes)
    }

    /// Send a request with a payload; returns the `seq` assigned.
    pub fn request(&mut self, msgid: u16, payload: Vec<u8>) -> Result<u32, TransportError> {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1).max(1);
        self.write_msg(&Message::request_with(msgid, seq, payload))?;
        Ok(seq)
    }

    /// Send a fire-and-forget notification (`seq = 0`).
    pub fn notify(&mut self, msgid: u16, payload: Vec<u8>) -> Result<(), TransportError> {
        let mut msg = Message::request_with(msgid, 0, payload);
        msg.mtype = crate::msg_type::NOTIFY;
        self.write_msg(&msg)
    }

    /// Feed inbound stream bytes (TCP); returns complete decoded messages.
    pub fn recv(&mut self, data: &[u8]) -> Vec<Message> {
        self.framer.feed(data).into_iter().filter_map(|b| decode_body(&b)).collect()
    }

    /// Decode one transport message (WebSocket): each message is one body.
    pub fn recv_message(&mut self, data: &[u8]) -> Option<Message> {
        decode_body(data)
    }
}

/// Built-in message ids (must match the server's `protocol.MSG`).
pub const HELLO_MSGID: u16 = 1;
pub const HELLO_ACK_MSGID: u16 = 2;

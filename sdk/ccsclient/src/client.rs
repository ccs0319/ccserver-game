//! Transport-agnostic client: sequence management + framing over a host-provided
//! transport. The host decides *how* bytes move (native TCP, `wx.connectSocket`
//! in a WeChat mini-game, a test harness, …).

use alloc::string::String;
use alloc::vec::Vec;

use crate::{decode_body, encode, Framer, Message};

/// Errors surfaced by the transport layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError(pub String);

/// Something that can send bytes to the server. The host implements this.
pub trait Transport {
    fn write(&mut self, data: &[u8]) -> Result<(), TransportError>;
}

/// A minimal protocol client.
///
/// * `request` / `notify` encode and write, returning the `seq` used.
/// * `recv` feeds inbound bytes and returns decoded [`Message`]s; match
///   responses to requests by `seq`.
pub struct Client<T: Transport> {
    transport: T,
    framer: Framer,
    next_seq: u32,
}

impl<T: Transport> Client<T> {
    pub fn new(transport: T) -> Self {
        Client { transport, framer: Framer::new(), next_seq: 1 }
    }

    pub fn transport(&self) -> &T {
        &self.transport
    }

    pub fn transport_mut(&mut self) -> &mut T {
        &mut self.transport
    }

    /// Send a request with a payload; returns the `seq` assigned.
    pub fn request(&mut self, msgid: u16, payload: Vec<u8>) -> Result<u32, TransportError> {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1).max(1);
        let msg = Message::request_with(msgid, seq, payload);
        self.transport.write(&encode(&msg))?;
        Ok(seq)
    }

    /// Send a fire-and-forget notification (`seq = 0`).
    pub fn notify(&mut self, msgid: u16, payload: Vec<u8>) -> Result<(), TransportError> {
        let mut msg = Message::request_with(msgid, 0, payload);
        msg.mtype = crate::msg_type::NOTIFY;
        self.transport.write(&encode(&msg))
    }

    /// HELLO handshake with the negotiated version.
    pub fn hello(&mut self) -> Result<u32, TransportError> {
        self.request(HELLO_MSGID, alloc::vec![crate::VERSION])
    }

    /// Feed inbound bytes; returns complete decoded messages.
    pub fn recv(&mut self, data: &[u8]) -> Vec<Message> {
        self.framer.feed(data).into_iter().filter_map(|b| decode_body(&b)).collect()
    }
}

/// Built-in message ids (must match the server's `protocol.MSG`).
pub const HELLO_MSGID: u16 = 1;
pub const HELLO_ACK_MSGID: u16 = 2;

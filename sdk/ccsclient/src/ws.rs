//! Native WebSocket transport (macOS / Windows / iOS / Android).
//!
//! Enabled with `feature = "ws"`. Uses `tungstenite` (rustls for `wss://`).
//! Because WebSocket already delimits messages, use
//! [`crate::client::Client::new_message`] with this transport.

use crate::client::{Transport, TransportError};

type Ws = tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<std::net::TcpStream>>;

/// A blocking WebSocket transport.
pub struct WsTransport {
    socket: Ws,
}

impl WsTransport {
    /// Connect to a `ws://` or `wss://` URL.
    pub fn connect(url: &str) -> Result<Self, String> {
        let (socket, _response) = tungstenite::connect(url).map_err(|e| e.to_string())?;
        Ok(WsTransport { socket })
    }

    /// Read the next binary/text message; `None` on close.
    pub fn read(&mut self) -> Result<Option<Vec<u8>>, String> {
        use tungstenite::Message;
        loop {
            match self.socket.read().map_err(|e| e.to_string())? {
                Message::Binary(b) => return Ok(Some(b.into())),
                Message::Text(t) => return Ok(Some(t.as_bytes().to_vec())),
                Message::Close(_) => return Ok(None),
                _ => continue, // ping / pong / frame
            }
        }
    }

    /// Send a close frame.
    pub fn close(&mut self) {
        let _ = self.socket.close(None);
    }
}

impl Transport for WsTransport {
    fn write(&mut self, data: &[u8]) -> Result<(), TransportError> {
        self.socket
            .write(tungstenite::Message::Binary(data.to_vec().into()))
            .map_err(|e| TransportError(e.to_string()))?;
        // tungstenite buffers outbound frames; flush so they hit the wire.
        self.socket.flush().map_err(|e| TransportError(e.to_string()))
    }
}

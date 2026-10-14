//! Native TCP transport (macOS / Windows / iOS / Android).
//!
//! Enabled with `feature = "native"`. The host drives the loop: read bytes and
//! feed them to [`crate::Client::recv`].

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use crate::client::{Transport, TransportError};

/// A blocking TCP transport.
pub struct TcpTransport {
    stream: TcpStream,
}

impl TcpTransport {
    /// Connect with a read timeout and `TCP_NODELAY`.
    pub fn connect(addr: &str, read_timeout: Duration) -> std::io::Result<Self> {
        let stream = TcpStream::connect(addr)?;
        stream.set_read_timeout(Some(read_timeout))?;
        let _ = stream.set_nodelay(true);
        Ok(TcpTransport { stream })
    }

    /// Read up to `buf.len()` bytes (blocks up to the read timeout).
    pub fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.stream.read(buf)
    }
}

impl Transport for TcpTransport {
    fn write(&mut self, data: &[u8]) -> Result<(), TransportError> {
        self.stream.write_all(data).map_err(|e| TransportError(e.to_string()))
    }
}

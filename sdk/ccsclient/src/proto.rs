//! Protobuf payload example (`feature = "proto"`).
//!
//! Demonstrates using `prost` types as the opaque payload. On the server, set
//! `protocol = { codec = "raw" }` so the payload bytes pass through unchanged and
//! the service decodes them with its own schema.
//!
//! You can derive `prost::Message` directly on a Rust struct (no `.proto` /
//! `protoc` needed) — or generate from a `.proto` in your build.

use alloc::string::String;
use alloc::vec::Vec;

use prost::Message as ProstMessage;

/// A sample request (the server's `raw` codec carries these bytes verbatim).
#[derive(Clone, PartialEq, prost::Message)]
pub struct LoginRequest {
    #[prost(string, tag = "1")]
    pub account: String,
    #[prost(string, tag = "2")]
    pub password: String,
}

/// A sample response.
#[derive(Clone, PartialEq, prost::Message)]
pub struct LoginResponse {
    #[prost(uint64, tag = "1")]
    pub uid: u64,
    #[prost(string, tag = "2")]
    pub token: String,
}

/// Encode a protobuf message to payload bytes.
pub fn encode<M: ProstMessage>(message: &M) -> Vec<u8> {
    message.encode_to_vec()
}

/// Decode payload bytes into a protobuf message.
pub fn decode<M: ProstMessage + Default>(bytes: &[u8]) -> Result<M, prost::DecodeError> {
    M::decode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn login_roundtrip() {
        let req = LoginRequest { account: "alice".into(), password: "pw".into() };
        let bytes = encode(&req);
        let back: LoginRequest = decode(&bytes).unwrap();
        assert_eq!(back, req);

        let resp = LoginResponse { uid: 1000, token: "a:1000:1".into() };
        let bytes = encode(&resp);
        assert_eq!(decode::<LoginResponse>(&bytes).unwrap(), resp);
    }
}

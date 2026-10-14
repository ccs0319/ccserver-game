//! Optional payload codec helpers.
//!
//! The protocol layer treats `payload` as opaque bytes; these helpers cover the
//! common encodings so callers don't hand-roll them.
//!
//! * **JSON** (`feature = "json"`): [`json`] wraps `serde_json`. The server's
//!   `json` codec encodes the request arguments as a JSON **array**, so a client
//!   typically sends a `serde_json::Value::Array`.
//! * **Protobuf**: bring your own `prost`-generated types and pass
//!   `Message::encode_to_vec()` bytes directly as the payload — no helper needed
//!   (the bytes are already opaque to this library).

#[cfg(feature = "json")]
pub mod json {
    use alloc::string::{String, ToString};
    use alloc::vec::Vec;
    use serde::{de::DeserializeOwned, Serialize};

    /// Encode a value to JSON payload bytes.
    pub fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, String> {
        serde_json::to_vec(value).map_err(|e| e.to_string())
    }

    /// Encode request arguments as a JSON array (matches the server `json` codec).
    pub fn encode_args<T: Serialize>(args: &[T]) -> Result<Vec<u8>, String> {
        encode(&args)
    }

    /// Decode JSON payload bytes into a value.
    pub fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, String> {
        serde_json::from_slice(bytes).map_err(|e| e.to_string())
    }

    /// Decode JSON payload bytes into an array of arguments.
    pub fn decode_args<T: DeserializeOwned>(bytes: &[u8]) -> Result<Vec<T>, String> {
        decode(bytes)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn args_roundtrip() {
            let args = alloc::vec!["alice".to_string(), "pw".to_string()];
            let bytes = encode_args(&args).unwrap();
            assert_eq!(bytes, br#"["alice","pw"]"#);
            let back: Vec<String> = decode_args(&bytes).unwrap();
            assert_eq!(back, args);
        }
    }
}

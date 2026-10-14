//! Native WebSocket client example.
//!
//! Build/run (against a running server started with `CCS_PROTOCOL_CODEC=json`
//! and a gateway `ws_addr`, e.g. `scripts/start.sh app/main.lua`):
//!
//! ```bash
//! CCS_WS_URL=ws://127.0.0.1:9011 \
//!   cargo run --example ws_client --features "ws,json"
//! ```

use ccsclient::codec::json;
use ccsclient::ws::WsTransport;
use ccsclient::{Client, Message};

const HELLO: u16 = 1;
const LOGIN: u16 = 10;
const ENTER: u16 = 12;
const MOVE: u16 = 14;

fn wait(client: &mut Client<WsTransport>, seq: u32) -> Option<Message> {
    loop {
        match client.transport_mut().read() {
            Ok(Some(data)) => {
                if let Some(m) = client.recv_message(&data) {
                    if m.mtype == ccsclient::msg_type::RESPONSE && m.seq == seq {
                        return Some(m);
                    }
                }
            }
            Ok(None) => {
                eprintln!("ws: closed");
                return None;
            }
            Err(e) => {
                eprintln!("ws read error: {e}");
                return None;
            }
        }
    }
}

fn main() {
    let url = std::env::var("CCS_WS_URL").unwrap_or_else(|_| "ws://127.0.0.1:9011".into());
    let transport = WsTransport::connect(&url).expect("ws connect");
    let mut client = Client::new_message(transport);

    // HELLO(version=1)
    let seq = client.request(HELLO, json::encode_args(&[1u8]).unwrap()).unwrap();
    let hello = wait(&mut client, seq).expect("hello");
    println!("HELLO -> {}", json::decode::<serde_json::Value>(&hello.payload).unwrap());

    // LOGIN("alice","pw")
    let seq = client.request(LOGIN, json::encode_args(&["alice", "pw"]).unwrap()).unwrap();
    let login = wait(&mut client, seq).expect("login");
    let login_json: serde_json::Value = json::decode(&login.payload).unwrap();
    println!("LOGIN -> {}", login_json);
    let token = login_json[1]["token"].as_str().expect("token").to_string();

    // ENTER(token, zone=1)
    let seq = client
        .request(ENTER, json::encode(&serde_json::json!([token, 1])).unwrap())
        .unwrap();
    let enter = wait(&mut client, seq).expect("enter");
    println!("ENTER -> {}", json::decode::<serde_json::Value>(&enter.payload).unwrap());

    // MOVE(5,6)
    let seq = client.request(MOVE, json::encode(&serde_json::json!([5, 6])).unwrap()).unwrap();
    let mv = wait(&mut client, seq).expect("move");
    println!("MOVE  -> {}", json::decode::<serde_json::Value>(&mv.payload).unwrap());

    client.transport_mut().close();
}

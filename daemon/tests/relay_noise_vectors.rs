//! Test vectors of the relay's Noise session (docs/RELAY.md), made with `snow`, the library the daemon runs. The Swift
//! initiator in BanditoKit (`NoiseIK`) reads the same file and must produce and accept exactly these bytes.
//!
//! Keys are fixed (never use them for anything real). `snow` takes the ephemeral keys from the test hook, so the
//! handshake is deterministic. To renew the file after a change of the protocol: `BANDITO_WRITE_VECTORS=1 cargo test
//! --test relay_noise_vectors`, then run the Swift `NoiseVectorTests` too.

use bandito::relay::{NOISE_PATTERN, NOISE_PROLOGUE};
use serde_json::{Value, json};
use std::path::PathBuf;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn key(seed: u8) -> Vec<u8> {
    // Any 32 bytes are an X25519 private key (the library clamps).
    (0..32u8).map(|i| seed.wrapping_add(i.wrapping_mul(7))).collect()
}

fn public_of(private: &[u8]) -> Vec<u8> {
    x25519_base(private)
}

/// X25519 of the base point (RFC 7748), for the public part of a fixed private key.
fn x25519_base(private: &[u8]) -> Vec<u8> {
    use snow::params::DHChoice;
    use snow::resolvers::{CryptoResolver, DefaultResolver};
    let mut dh = DefaultResolver.resolve_dh(&DHChoice::Curve25519).unwrap();
    dh.set(private);
    dh.pubkey().to_vec()
}

fn builder<'a>(statics: &'a [u8], eph: &'a [u8], remote: Option<&'a [u8]>) -> snow::Builder<'a> {
    let params: snow::params::NoiseParams = NOISE_PATTERN.parse().unwrap();
    let mut b = snow::Builder::new(params)
        .local_private_key(statics)
        .unwrap()
        .prologue(NOISE_PROLOGUE)
        .unwrap()
        .fixed_ephemeral_key_for_testing_only(eph);
    if let Some(remote) = remote {
        b = b.remote_public_key(remote).unwrap();
    }
    b
}

fn vectors() -> Value {
    let (is, rs) = (key(0x11), key(0x42));
    let (ie, re) = (key(0x73), key(0x9d));
    let (is_pub, rs_pub) = (public_of(&is), public_of(&rs));

    let mut initiator = builder(&is, &ie, Some(&rs_pub)).build_initiator().unwrap();
    let mut responder = builder(&rs, &re, None).build_responder().unwrap();
    let hello = br#"{"v":1}"#;
    let mut buf = vec![0u8; 65535];
    let mut out = vec![0u8; 65535];

    let n = initiator.write_message(hello, &mut buf).unwrap();
    let msg1 = buf[..n].to_vec();
    let m = responder.read_message(&msg1, &mut out).unwrap();
    assert_eq!(&out[..m], hello);
    assert_eq!(responder.get_remote_static().unwrap(), &is_pub[..]);

    let n = responder.write_message(hello, &mut buf).unwrap();
    let msg2 = buf[..n].to_vec();
    let m = initiator.read_message(&msg2, &mut out).unwrap();
    assert_eq!(&out[..m], hello);

    let mut i = initiator.into_transport_mode().unwrap();
    let mut r = responder.into_transport_mode().unwrap();
    // First message of a session is `[more=0]{"auth":..}`; then an RPC frame; then an empty frame (`[0]`).
    let to_daemon: Vec<Vec<u8>> = vec![
        [&[0u8][..], br#"{"auth":"tok"}"#].concat(),
        [&[0u8][..], br#"{"jsonrpc":"2.0","id":1,"method":"daemon.hello"}"#].concat(),
        vec![0u8],
    ];
    let to_phone: Vec<Vec<u8>> = vec![
        [&[0u8][..], br#"{"jsonrpc":"2.0","id":1,"result":{}}"#].concat(),
        [&[1u8][..], b"first-chunk"].concat(),
        [&[0u8][..], b"last-chunk"].concat(),
    ];
    let mut sealed_to_daemon = Vec::new();
    for plain in &to_daemon {
        let n = i.write_message(plain, &mut buf).unwrap();
        let cipher = buf[..n].to_vec();
        let m = r.read_message(&cipher, &mut out).unwrap();
        assert_eq!(&out[..m], &plain[..]);
        sealed_to_daemon.push(json!({"plain": hex(plain), "cipher": hex(&cipher)}));
    }
    let mut sealed_to_phone = Vec::new();
    for plain in &to_phone {
        let n = r.write_message(plain, &mut buf).unwrap();
        let cipher = buf[..n].to_vec();
        let m = i.read_message(&cipher, &mut out).unwrap();
        assert_eq!(&out[..m], &plain[..]);
        sealed_to_phone.push(json!({"plain": hex(plain), "cipher": hex(&cipher)}));
    }

    json!({
        "pattern": NOISE_PATTERN,
        "prologue": hex(NOISE_PROLOGUE),
        "initiator_static_private": hex(&is),
        "initiator_static_public": hex(&is_pub),
        "responder_static_private": hex(&rs),
        "responder_static_public": hex(&rs_pub),
        "initiator_ephemeral_private": hex(&ie),
        "responder_ephemeral_private": hex(&re),
        "message1_payload": hex(hello),
        "message1": hex(&msg1),
        "message2_payload": hex(hello),
        "message2": hex(&msg2),
        "initiator_to_responder": sealed_to_daemon,
        "responder_to_initiator": sealed_to_phone,
    })
}

fn file() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/noise_ik_vectors.json")
}

#[test]
fn the_committed_noise_vectors_are_what_snow_makes() {
    let made = vectors();
    if std::env::var("BANDITO_WRITE_VECTORS").is_ok() {
        std::fs::write(file(), serde_json::to_string_pretty(&made).unwrap() + "\n").unwrap();
    }
    let kept: Value =
        serde_json::from_str(&std::fs::read_to_string(file()).expect("run with BANDITO_WRITE_VECTORS=1")).unwrap();
    assert_eq!(
        made, kept,
        "renew with BANDITO_WRITE_VECTORS=1 and check the Swift NoiseVectorTests"
    );
}

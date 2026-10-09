//! Bandito daemon library: store, runtimes, policy, RPC. The `bandito` binary is a thin CLI over it.

pub mod browser;
pub mod cdp;
pub mod checkpoint;
pub mod crew;
pub mod event;
pub mod files;
pub mod home;
pub mod host;
pub mod hub;
pub mod pairing;
pub mod policy;
pub mod redact;
pub mod rpc;
pub mod runtime;
pub mod scheduler;
pub mod service;
pub mod setup;
pub mod store;
pub mod supervisor;
pub mod terminal;

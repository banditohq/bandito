//! The event hub: persist an event, then fan it out to live subscribers.

use crate::event::{Event, EventBody};
use crate::store::Store;
use std::sync::Arc;
use tokio::sync::broadcast;

#[derive(Clone)]
pub struct Hub {
    pub store: Arc<Store>,
    tx: broadcast::Sender<Event>,
}

impl Hub {
    pub fn new(store: Arc<Store>) -> Self {
        let (tx, _) = broadcast::channel(1024);
        Self { store, tx }
    }

    /// Store (unless it's a delta) and broadcast. Usage limits also update the
    /// usage cache. A storage error is logged and the event is still broadcast
    /// with `seq = 0`, so a full disk does not freeze agents.
    pub fn emit(&self, agent_id: &str, body: EventBody) -> Event {
        if let EventBody::UsageLimits { runtime, windows } = &body
            && let Err(e) = self.store.usage_set(runtime, windows, crate::store::now_ms())
        {
            tracing::warn!(runtime, "cache usage limits: {e:#}");
        }
        let ev = match self.store.append_event(agent_id, body.clone()) {
            Ok(ev) => ev,
            Err(e) => {
                tracing::error!(agent_id, "store event: {e:#}");
                Event {
                    seq: 0,
                    agent_id: agent_id.to_string(),
                    ts: crate::store::now_ms(),
                    body,
                }
            }
        };
        // No subscribers is fine.
        let _ = self.tx.send(ev.clone());
        ev
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.tx.subscribe()
    }
}

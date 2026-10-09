//! Child processes whose owner waits for them. The zombie reaper (`rpc::unix`) leaves these alone:
//! their owner reaps them, and reaping them first would take their exit status away. A child is
//! registered when it starts and forgotten when its owner has waited for it.

use std::collections::HashSet;
use std::sync::{Mutex, MutexGuard};

static LIVE: Mutex<Option<HashSet<u32>>> = Mutex::new(None);

fn live() -> MutexGuard<'static, Option<HashSet<u32>>> {
    LIVE.lock().unwrap_or_else(|e| e.into_inner())
}

/// Records a child that its owner will wait for.
pub fn register(pid: u32) {
    live().get_or_insert_with(HashSet::new).insert(pid);
}

/// Forgets a child, once its owner has waited for it.
pub fn unregister(pid: u32) {
    if let Some(set) = live().as_mut() {
        set.remove(&pid);
    }
}

/// Whether the pid belongs to a child whose owner is still to wait for it.
pub fn is_registered(pid: u32) -> bool {
    live().as_ref().is_some_and(|set| set.contains(&pid))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_child_is_registered_until_its_owner_waits() {
        // A pid no process of this test run has.
        let pid = 4_000_000;
        assert!(!is_registered(pid));
        register(pid);
        assert!(is_registered(pid));
        unregister(pid);
        assert!(!is_registered(pid));
    }
}

//! Child processes whose owner waits for them. The zombie reaper (`rpc::unix`) leaves these alone:
//! their owner reaps them, and reaping them first would take their exit status away. A child is
//! registered after its spawn succeeded, and the registration ends when its owner drops it (also
//! while unwinding from a panic), or when the owner has waited for the child and releases it.

use std::collections::HashSet;
use std::ops::{Deref, DerefMut};
use std::sync::{Mutex, MutexGuard};
use tokio::process::Child;

static LIVE: Mutex<Option<HashSet<u32>>> = Mutex::new(None);

fn live() -> MutexGuard<'static, Option<HashSet<u32>>> {
    LIVE.lock().unwrap_or_else(|e| e.into_inner())
}

/// A pid the owner will wait for. Dropping it forgets the pid.
#[must_use = "dropping the registration at once forgets the child"]
#[derive(Debug)]
pub struct Registration {
    pid: u32,
}

/// Records a child that its owner will wait for. Keep the guard as long as the child is owned.
pub fn register(pid: u32) -> Registration {
    live().get_or_insert_with(HashSet::new).insert(pid);
    Registration { pid }
}

impl Drop for Registration {
    fn drop(&mut self) {
        if let Some(set) = live().as_mut() {
            set.remove(&self.pid);
        }
    }
}

/// Whether the pid belongs to a child whose owner is still to wait for it.
pub fn is_registered(pid: u32) -> bool {
    live().as_ref().is_some_and(|set| set.contains(&pid))
}

/// A tokio child with its registration. It derefs to the child, so it is used like one.
pub struct TrackedChild {
    child: Child,
    registration: Option<Registration>,
}

impl TrackedChild {
    pub fn new(child: Child) -> Self {
        let registration = child.id().map(register);
        Self { child, registration }
    }

    /// Ends the registration. Call it once the child has been waited for.
    pub fn release(&mut self) {
        self.registration.take();
    }
}

impl Deref for TrackedChild {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.child
    }
}

impl DerefMut for TrackedChild {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.child
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_registration_lasts_as_long_as_its_guard() {
        // A pid no process of this test run has.
        let pid = 4_000_000;
        assert!(!is_registered(pid));
        let guard = register(pid);
        assert!(is_registered(pid));
        drop(guard);
        assert!(!is_registered(pid));
    }

    #[test]
    fn a_panic_forgets_the_pid_too() {
        let pid = 4_000_001;
        let result = std::panic::catch_unwind(|| {
            let _guard = register(pid);
            panic!("the owner panics");
        });
        assert!(result.is_err());
        assert!(!is_registered(pid));
    }
}

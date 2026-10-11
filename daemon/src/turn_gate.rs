//! How many agents run a turn at once (`max_running_agents`, docs/ARCHITECTURE.md#server-settings). Every agent's
//! supervisor takes a slot before its turn starts and gives it back when the agent is idle again. An agent that finds
//! no slot keeps its message in its queue (shown as queued) and waits: the gate tells it when a slot is free.
//! The gate is shared by all agents of one daemon (it lives in the [`crate::hub::Hub`]).
//!
//! A hold ([`IdleHold`]) closes the gate for new turns, so that a check of "no turn runs" stays true while the
//! holder acts (the night install, see `update::spawn_auto_install`). New turns wait like turns past the limit.

use std::sync::{Arc, Mutex, MutexGuard};
use tokio::sync::watch;

#[derive(Default)]
struct State {
    /// Slots taken: the turns running now.
    running: usize,
    /// Holds in force. While any is, no slot is given.
    holds: usize,
}

pub struct TurnGate {
    state: Mutex<State>,
    /// Counts every change of the gate: a slot given back, a hold ended, or a wake after a settings change. A waiting
    /// agent watches it, so a change between its check and its wait is not missed.
    changes: watch::Sender<u64>,
}

impl TurnGate {
    pub fn new() -> Arc<Self> {
        let (changes, _) = watch::channel(0);
        Arc::new(Self {
            state: Mutex::new(State::default()),
            changes,
        })
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A slot, when no hold is in force and fewer than `limit` slots are taken. `usize::MAX` means no limit.
    pub fn try_take(self: &Arc<Self>, limit: usize) -> Option<TurnSlot> {
        let mut state = self.state();
        if state.holds > 0 || state.running >= limit {
            return None;
        }
        state.running += 1;
        Some(TurnSlot { gate: Arc::clone(self) })
    }

    /// True when [`Self::try_take`] would give a slot now.
    pub fn has_room(&self, limit: usize) -> bool {
        let state = self.state();
        state.holds == 0 && state.running < limit
    }

    /// How many slots are taken: the turns running now.
    pub fn running(&self) -> usize {
        self.state().running
    }

    /// Closes the gate for new turns, if `allow` says so for the number of running turns. The count and the closing
    /// happen under one lock: no turn can start between them. `allow` gets the count and returns whether to hold
    /// (for example `update::may_install`). `None` means `allow` said no, and the gate is left as it was.
    pub fn close_when(self: &Arc<Self>, allow: impl FnOnce(usize) -> bool) -> Option<IdleHold> {
        let mut state = self.state();
        if !allow(state.running) {
            return None;
        }
        state.holds += 1;
        Some(IdleHold { gate: Arc::clone(self) })
    }

    /// A receiver that sees every later change of the gate (see `changes`).
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    /// Tells every waiting agent to check again (after the limit changed).
    pub fn wake(&self) {
        self.changes.send_modify(|n| *n = n.wrapping_add(1));
    }
}

/// A taken slot. Dropping it gives the slot back and wakes the waiting agents.
pub struct TurnSlot {
    gate: Arc<TurnGate>,
}

impl Drop for TurnSlot {
    fn drop(&mut self) {
        {
            let mut state = self.gate.state();
            state.running = state.running.saturating_sub(1);
        }
        self.gate.wake();
    }
}

/// A hold on the gate: no new turn starts while it lives. Dropping it lets the waiting turns start.
pub struct IdleHold {
    gate: Arc<TurnGate>,
}

impl Drop for IdleHold {
    fn drop(&mut self) {
        {
            let mut state = self.gate.state();
            state.holds = state.holds.saturating_sub(1);
        }
        self.gate.wake();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slots_stop_at_the_limit_and_come_back_on_drop() {
        let gate = TurnGate::new();
        let first = gate.try_take(1).expect("the first slot");
        assert_eq!(gate.running(), 1);
        assert!(!gate.has_room(1));
        assert!(gate.try_take(1).is_none());
        drop(first);
        assert_eq!(gate.running(), 0);
        assert!(gate.try_take(1).is_some());
    }

    #[test]
    fn no_limit_takes_any_number() {
        let gate = TurnGate::new();
        let slots: Vec<_> = (0..5).map(|_| gate.try_take(usize::MAX).unwrap()).collect();
        assert_eq!(gate.running(), 5);
        drop(slots);
        assert_eq!(gate.running(), 0);
    }

    #[test]
    fn a_giving_back_or_a_wake_is_seen_by_a_waiter() {
        let gate = TurnGate::new();
        let mut rx = gate.subscribe();
        rx.borrow_and_update();
        let slot = gate.try_take(1).unwrap();
        assert!(!rx.has_changed().unwrap(), "taking a slot is not a change to wait for");
        drop(slot);
        assert!(rx.has_changed().unwrap());
        rx.borrow_and_update();
        gate.wake();
        assert!(rx.has_changed().unwrap());
    }

    #[test]
    fn a_hold_closes_the_gate_for_new_turns_and_its_end_opens_it() {
        let gate = TurnGate::new();
        let hold = gate
            .close_when(|running| running == 0)
            .expect("nothing runs: the hold is taken");
        assert!(
            gate.try_take(usize::MAX).is_none(),
            "a new turn waits while the hold lives"
        );
        assert!(!gate.has_room(usize::MAX), "the waiting message is shown as queued");
        let mut rx = gate.subscribe();
        rx.borrow_and_update();
        drop(hold);
        assert!(rx.has_changed().unwrap(), "the waiting agents are woken");
        assert!(gate.try_take(usize::MAX).is_some());
    }

    #[test]
    fn a_running_turn_leaves_the_gate_open() {
        let gate = TurnGate::new();
        let slot = gate.try_take(usize::MAX).unwrap();
        assert!(gate.close_when(|running| running == 0).is_none());
        // Not closed by the refused attempt: a new turn starts at once.
        assert!(gate.try_take(usize::MAX).is_some());
        drop(slot);
    }
}

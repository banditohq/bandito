//! How many agents run a turn at once (`max_running_agents`, docs/ARCHITECTURE.md#server-settings). Every agent's
//! supervisor takes a slot before its turn starts and gives it back when the agent is idle again. An agent that finds
//! no slot keeps its message in its queue (shown as queued) and waits in line.
//!
//! The line is first come, first served: an agent that asks gets a ticket at the end of it ([`SlotWait`]), and a
//! slot goes only to the ticket at the front. An agent that gives its slot back and asks again (a long queue of
//! messages) therefore goes to the end, behind everyone already waiting.
//!
//! A hold ([`IdleHold`]) closes the gate for new turns, so that a check of "no turn runs" stays true while the holder
//! acts (the night install, see `update::spawn_auto_install`). New turns wait in line like turns past the limit.
//! The gate is shared by all agents of one daemon (it lives in the [`crate::hub::Hub`]).

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};
use tokio::sync::watch;

#[derive(Default)]
struct State {
    /// Slots taken: the turns running now.
    running: usize,
    /// Holds in force. While any is, no slot is given.
    holds: usize,
    /// The tickets of the agents waiting for a slot, first in line at the front.
    waiting: VecDeque<u64>,
    /// The next ticket number.
    next_ticket: u64,
}

pub struct TurnGate {
    state: Mutex<State>,
    /// Counts every change of the gate: a slot given back or taken, a hold or a ticket ended, or a wake after a
    /// settings change. A waiting agent watches it, so a change between its check and its wait is not missed.
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

    /// Asks for a slot: takes a ticket at the end of the line. Ask again with [`Self::take`]. Dropping the ticket
    /// (see [`SlotWait`]) leaves the line.
    pub fn join(self: &Arc<Self>) -> SlotWait {
        let mut state = self.state();
        let ticket = state.next_ticket;
        state.next_ticket += 1;
        state.waiting.push_back(ticket);
        SlotWait {
            gate: Arc::clone(self),
            ticket,
        }
    }

    /// The slot of `wait`, when it is first in line, no hold is in force and fewer than `limit` slots are taken.
    /// `usize::MAX` means no limit. The ticket is used up by a slot.
    pub fn take(self: &Arc<Self>, wait: &SlotWait, limit: usize) -> Option<TurnSlot> {
        let mut state = self.state();
        if state.holds > 0 || state.running >= limit || state.waiting.front() != Some(&wait.ticket) {
            return None;
        }
        state.waiting.pop_front();
        state.running += 1;
        drop(state);
        // The next one in line may go now.
        self.wake();
        Some(TurnSlot { gate: Arc::clone(self) })
    }

    /// A slot now, when nobody is in line before and one is free. A test helper and a shortcut: an agent that keeps
    /// its ticket uses [`Self::join`] and [`Self::take`].
    pub fn try_take(self: &Arc<Self>, limit: usize) -> Option<TurnSlot> {
        let wait = self.join();
        self.take(&wait, limit)
    }

    /// True when a new asker would get a slot now: no hold, nobody in line, and a slot free.
    pub fn has_room(&self, limit: usize) -> bool {
        let state = self.state();
        state.holds == 0 && state.waiting.is_empty() && state.running < limit
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

/// A place in the line for a slot. Dropping it leaves the line (and wakes the agents behind it).
pub struct SlotWait {
    gate: Arc<TurnGate>,
    ticket: u64,
}

impl SlotWait {
    /// The ticket's number: a smaller one was asked for earlier.
    pub fn ticket(&self) -> u64 {
        self.ticket
    }
}

impl Drop for SlotWait {
    fn drop(&mut self) {
        let removed = {
            let mut state = self.gate.state();
            match state.waiting.iter().position(|t| *t == self.ticket) {
                Some(at) => {
                    state.waiting.remove(at);
                    true
                }
                None => false,
            }
        };
        if removed {
            self.gate.wake();
        }
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
        assert!(
            rx.has_changed().unwrap(),
            "a taken slot is a change the others may need to see"
        );
        rx.borrow_and_update();
        drop(slot);
        assert!(rx.has_changed().unwrap());
        rx.borrow_and_update();
        gate.wake();
        assert!(rx.has_changed().unwrap());
    }

    /// Agents A, B and C ask for the one slot in that order. The slot goes to them in that order, whatever the
    /// timing of their checks, and an agent that gives its slot back goes to the end of the line.
    #[test]
    fn slots_are_given_in_the_order_of_asking() {
        let gate = TurnGate::new();
        let a = gate.join();
        let b = gate.join();
        let c = gate.join();
        assert!(a.ticket() < b.ticket() && b.ticket() < c.ticket());

        let first = gate.take(&a, 1).expect("A asked first");
        assert!(gate.take(&b, 1).is_none(), "B waits behind A");
        assert!(gate.take(&c, 1).is_none(), "C waits behind A and B");
        drop(first);
        // C checks before B does: it still waits its turn in line.
        assert!(gate.take(&c, 1).is_none(), "C does not overtake B");
        let second = gate.take(&b, 1).expect("B is next");
        assert!(gate.take(&c, 1).is_none());
        drop(second);
        assert!(gate.take(&c, 1).is_some(), "C is last and gets the slot");
    }

    #[test]
    fn an_agent_that_asks_again_goes_to_the_end_of_the_line() {
        let gate = TurnGate::new();
        let a = gate.join();
        let first = gate.take(&a, 1).expect("A runs");
        // B waits while A runs; then A gives its slot back and asks again (a long message queue).
        let b = gate.join();
        drop(first);
        let a_again = gate.join();
        assert!(gate.take(&a_again, 1).is_none(), "A is behind B");
        assert!(gate.take(&b, 1).is_some(), "B takes the slot A gave back");
        drop(a);
        drop(a_again);
    }

    #[test]
    fn leaving_the_line_lets_the_next_one_in() {
        let gate = TurnGate::new();
        let holder = gate.try_take(1).expect("a slot is held");
        let gone = gate.join();
        let next = gate.join();
        let mut rx = gate.subscribe();
        rx.borrow_and_update();
        drop(gone);
        assert!(rx.has_changed().unwrap(), "the line moved: the agents behind are woken");
        drop(holder);
        assert!(
            gate.take(&next, 1).is_some(),
            "the one behind the gone ticket is first now"
        );
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

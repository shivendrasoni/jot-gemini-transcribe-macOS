// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// The pure hotkey grammar (Wispr style — critic reconciliation #1):
///
///   hold ≥ 0.3s            → push-to-talk: key-up finalizes
///   tap, tap (≤ 0.35s gap) → hands-free lock: press again finalizes
///   single tap             → coaching hint, session quietly cancelled
///   Esc                    → cancel
///   other key < 1s in      → accidental chord, silent abort
///
/// Recording ALWAYS starts on the first key-down (`.begin`) so no audio is ever
/// lost while the grammar disambiguates. Between the taps of a double-tap the
/// session keeps recording.
///
/// Pure and clock-free: callers pass monotonic timestamps; timers are returned as
/// effects and fed back in as `.doubleTapTimeout`. Exhaustively unit-tested.
public struct HotkeyProcessor {
    public enum Event: Equatable, Sendable {
        case hotkeyDown
        case hotkeyUp
        case escDown
        case otherKeyDown
        /// Space pressed while the hotkey is physically held — the timing-free
        /// hands-free gesture ("hold, tap Space, let go").
        case spaceLock
        /// The double-tap window expired (fed back by the timer the caller armed).
        case doubleTapTimeout
        /// Option went down while the dictation key is held — the Transform
        /// picker's modifier.
        case optionDown
        case optionUp
        /// The wheel-reveal delay expired (fed back by the timer the caller armed).
        case wheelRevealTimeout
        /// Arrow key while the wheel is up.
        case pickerMove(Int)
        /// A slot key (digit or letter) pressed with Option held.
        case pickerSlot(TransformShortcut)
    }

    public struct Effects: Equatable, Sendable {
        public var intents: [HotkeyIntent] = []
        /// Arm the double-tap timer to fire after this many seconds (nil = leave as-is).
        public var armTimer: TimeInterval?
        public var disarmTimer = false
        /// Arm the wheel-reveal timer. A separate timer from the double-tap one
        /// because the two can legitimately be in flight at once.
        public var armWheelTimer: TimeInterval?
        public var disarmWheelTimer = false
    }

    /// Whether the Transform wheel is up, and where the highlight sits.
    ///
    /// Deliberately NOT a case inside `Phase`. The picker can be open while
    /// pressed or while locked and changes nothing about what a key-up means,
    /// so folding it in would square the state space — `pressed`×picker,
    /// `locked`×picker — and every exhaustive test case with it.
    public enum PickerState: Equatable, Sendable {
        case closed
        case open(highlighted: Int)
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Key physically down, classification pending (hold vs tap).
        case pressed(downAt: TimeInterval, sessionStartAt: TimeInterval)
        /// First short tap released; waiting for a possible second tap. Still recording.
        case pendingSecondTap(sessionStartAt: TimeInterval)
        /// Hands-free.
        case locked
    }

    public private(set) var phase: Phase = .idle
    public private(set) var picker: PickerState = .closed
    /// The slot armed for this dictation, if any. Cleared with the session.
    public private(set) var armedSlot: TransformShortcut?
    /// How many Transforms the wheel has to show. Pushed in by the controller,
    /// the same way `doubleTapLockEnabled` is, so this type stays store-free.
    public var wheelSlotCount = 0
    /// True while Option is physically down during a session.
    private var optionIsDown = false

    /// Snap back to idle after the coordinator REFUSES a begin (secure field,
    /// busy) — otherwise a Space-lock on the phantom session strands the grammar
    /// in .locked and silently eats the next dictation attempt.
    public mutating func reset() {
        phase = .idle
        swallowNextUp = false
        clearPicker()
    }

    private mutating func clearPicker() {
        picker = .closed
        armedSlot = nil
        optionIsDown = false
    }
    /// When off, a short tap hints immediately and never arms the double-tap
    /// window — for users who find tap-tap colliding with quick holds.
    /// Default OFF since dogfood: firm taps routinely exceed the hold threshold,
    /// misreading tap-tap as hold→finalize. Space-while-holding replaced it.
    public var doubleTapLockEnabled = false
    /// True while the hotkey is physically down (the Space-lock gesture window).
    public var isKeyHeld: Bool {
        if case .pressed = phase { return true }
        return false
    }
    /// True whenever a dictation session is in flight from the hotkey's perspective —
    /// the event tap uses this to decide whether to intercept Esc.
    public var isSessionActive: Bool { phase != .idle }
    /// When set, the next key-up of the hotkey belongs to an already-classified press
    /// (lock stop, cancel, abort) and must be swallowed without effects.
    private var swallowNextUp = false

    public init() {}

    public mutating func handle(_ event: Event, at now: TimeInterval) -> Effects {
        if let fx = handlePicker(event) { return fx }

        var fx = Effects()
        // A session ending takes the wheel with it — otherwise a wheel raised on
        // the last dictation is still up, and still armed, on the next one.
        defer { if phase == .idle { clearPicker() } }
        switch (phase, event) {

        // MARK: idle
        case (.idle, .hotkeyDown):
            phase = .pressed(downAt: now, sessionStartAt: now)
            swallowNextUp = false
            fx.intents = [.begin]

        case (.idle, .hotkeyUp):
            // Residual up from a press we already classified (lock stop, cancel…).
            swallowNextUp = false

        case (.idle, _):
            break

        // MARK: pressed (key down, disambiguating)
        case (.pressed(let downAt, let startAt), .hotkeyUp):
            if swallowNextUp {
                swallowNextUp = false
                break
            }
            if now - downAt >= HotkeyTuning.holdThreshold {
                phase = .idle
                fx.intents = [.finalize]
            } else if doubleTapLockEnabled {
                phase = .pendingSecondTap(sessionStartAt: startAt)
                fx.armTimer = HotkeyTuning.doubleTapWindow
            } else {
                phase = .idle
                fx.intents = [.shortTapHint]
            }

        case (.pressed, .escDown):
            phase = .idle
            swallowNextUp = true
            fx.intents = [.cancel]

        case (.pressed(_, let startAt), .otherKeyDown):
            if now - startAt < HotkeyTuning.interruptionWindow {
                phase = .idle
                swallowNextUp = true
                fx.intents = [.abortAccidental]
            }
            // After the window: user is deliberately chording/typing mid-hold — keep going.

        case (.pressed, .spaceLock):
            // Hold + tap Space = hands-free, no timing window. The fn release that
            // follows belongs to this gesture and must not finalize.
            phase = .locked
            swallowNextUp = true
            fx.intents = [.lockIn]

        case (.pressed, .hotkeyDown), (.pressed, .doubleTapTimeout):
            break

        // MARK: pendingSecondTap (short tap released, window open, still recording)
        case (.pendingSecondTap, .hotkeyDown):
            phase = .locked
            swallowNextUp = true
            fx.intents = [.lockIn]
            fx.disarmTimer = true

        case (.pendingSecondTap, .doubleTapTimeout):
            phase = .idle
            fx.intents = [.shortTapHint]

        case (.pendingSecondTap, .escDown):
            phase = .idle
            fx.intents = [.cancel]
            fx.disarmTimer = true

        case (.pendingSecondTap(let startAt), .otherKeyDown):
            phase = .idle
            fx.disarmTimer = true
            fx.intents = [now - startAt < HotkeyTuning.interruptionWindow ? .abortAccidental : .cancel]

        case (.pendingSecondTap, .hotkeyUp):
            swallowNextUp = false

        case (.pendingSecondTap, .spaceLock):
            break // key not held — Space types normally

        // MARK: locked (hands-free)
        case (.locked, .hotkeyDown):
            phase = .idle
            swallowNextUp = true
            fx.intents = [.finalize]

        case (.locked, .escDown):
            phase = .idle
            fx.intents = [.cancel]

        case (.locked, .hotkeyUp):
            swallowNextUp = false

        case (.locked, .otherKeyDown), (.locked, .doubleTapTimeout), (.locked, .spaceLock):
            break

        // Picker events never reach here — handlePicker consumed them.
        case (_, .optionDown), (_, .optionUp), (_, .wheelRevealTimeout),
             (_, .pickerMove), (_, .pickerSlot):
            break
        }
        return fx
    }

    // MARK: - The Transform picker

    /// Handles the picker's own events, and steals `.escDown` while the wheel is
    /// up. Returns nil for anything the phase machine should see.
    ///
    /// Running BEFORE the phase switch is what keeps the two machines
    /// independent: no picker event can produce a phase transition, and in
    /// particular `.pickerSlot` can never be mistaken for the `.otherKeyDown`
    /// that aborts an accidental chord.
    private mutating func handlePicker(_ event: Event) -> Effects? {
        var fx = Effects()
        switch event {
        case .optionDown:
            // Meaningless with nothing recording — there is no transcript for a
            // Transform to run on, and the user is just typing an accent.
            guard isSessionActive, wheelSlotCount > 0 else { return fx }
            optionIsDown = true
            fx.armWheelTimer = HotkeyTuning.wheelRevealDelay
            return fx

        case .wheelRevealTimeout:
            guard optionIsDown, isSessionActive, wheelSlotCount > 0 else { return fx }
            picker = .open(highlighted: highlightIndexForArmedSlot())
            fx.intents = [.showTransformWheel]
            return fx

        case .optionUp:
            optionIsDown = false
            fx.disarmWheelTimer = true
            guard case .open(let highlighted) = picker else { return fx }
            picker = .closed
            // Releasing Option over the wheel is the commit gesture.
            let slot = TransformShortcut.slots.indices.contains(highlighted)
                ? TransformShortcut.slots[highlighted] : nil
            armedSlot = slot
            fx.intents = [.armTransform(slot), .dismissWheel]
            return fx

        case .pickerMove(let delta):
            guard case .open(let highlighted) = picker else { return fx }
            let moved = min(max(highlighted + delta, 0), wheelSlotCount - 1)
            picker = .open(highlighted: moved)
            fx.intents = [.moveWheel(moved)]
            return fx

        case .pickerSlot(let slot):
            guard isSessionActive else { return fx }
            fx.disarmWheelTimer = true
            let wasOpen = picker != .closed
            picker = .closed
            // Same slot twice disarms. A toggle means there is no separate
            // "clear" chord to learn, and no way to be stuck armed.
            let next: TransformShortcut? = (armedSlot == slot) ? nil : slot
            armedSlot = next
            fx.intents = wasOpen ? [.armTransform(next), .dismissWheel] : [.armTransform(next)]
            return fx

        case .escDown where picker != .closed:
            // Esc is the universal back-out. Cancelling a whole dictation
            // because the user closed a menu they did not want would kill trust
            // in the wheel permanently.
            picker = .closed
            fx.disarmWheelTimer = true
            fx.intents = [.dismissWheel]
            return fx

        default:
            return nil
        }
    }

    /// Opens the wheel on the armed Transform when there is one, so a reopen
    /// shows where you already are rather than snapping back to the first card.
    private func highlightIndexForArmedSlot() -> Int {
        guard let armedSlot,
              let index = TransformShortcut.slots.firstIndex(of: armedSlot),
              index < wheelSlotCount
        else { return 0 }
        return index
    }
}

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

import AppKit
import CoreGraphics
import Foundation

/// Owns the system-wide CGEventTap that powers the bare-modifier dictation key.
///
/// Design (docs/design/architecture.md — HotkeyEngine):
///  - Dedicated thread with its own CFRunLoop; the callback only classifies events,
///    runs the pure `HotkeyProcessor` under a lock (microseconds), and forwards
///    intents to the owner via a closure.
///  - Consumes the configured key's flagsChanged events (that's what makes fn *ours*)
///    and Esc key-downs, but ONLY while a session is active. Everything else passes.
///  - Self-healing: re-enables on kCGEventTapDisabledBy* and polls tapIsEnabled
///    every 5s — a non-nil tap is not a healthy tap.
public final class EventTapEngine {
    public enum State: Equatable {
        case stopped
        /// Tap creation failed — Accessibility permission is missing.
        case permissionDenied
        case running
    }

    public private(set) var state: State = .stopped

    /// Called with each intent, on an arbitrary internal thread — the owner hops
    /// to the main actor.
    public var onIntent: ((HotkeyIntent) -> Void)?
    /// Called when the tap had to be revived (telemetry for the #1 field failure).
    public var onTapRevived: (() -> Void)?

    private var key: HotkeyKey
    private let lock = NSLock()
    private var processor = HotkeyProcessor()
    private var keyIsDown = false
    /// Set by the app while a session is in flight beyond the grammar's view
    /// (transcribing/inserting, or UI-started hands-free) so Esc still cancels
    /// (audit L8/L13 — the machine supported cancel, the tap never delivered it).
    private var externalSessionActive = false

    private var tapThread: Thread?
    private var tapPort: CFMachPort?
    private var runLoop: CFRunLoop?
    private let timerQueue = DispatchQueue(label: "com.ammaar.jot.hotkey.timer")
    private var doubleTapTimer: DispatchSourceTimer?
    /// Separate from the double-tap timer: both can legitimately be in flight,
    /// and sharing one would make a Transform choice cancel a lock gesture.
    private var wheelTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?

    /// Left and right Option. Observed, never consumed — Option is load-bearing
    /// for ordinary typing (every accented character on a Mac) and swallowing it
    /// would break the keyboard for anyone mid-dictation.
    private static let optionKeyCodes: Set<Int64> = [58, 61]
    /// Left, right, down, up.
    private static let arrowKeyCodes: Set<Int64> = [123, 124, 125, 126]

    /// Whether the picker's Option key is physically down.
    ///
    /// Tracked from flagsChanged rather than read off `.maskAlternate` on the
    /// keystroke, because Right ⌥ is a selectable DICTATION key: holding it sets
    /// `.maskAlternate` for the entire dictation, so a flag test would hijack
    /// every digit and arrow that user types for the whole hold.
    private var pickerModifierDown = false

    /// True for an Option key that is not the user's dictation key. When Right ⌥
    /// IS the dictation key, Left ⌥ still drives the picker — the gesture
    /// survives, and the key doing the dictating is never also the modifier.
    private func isPickerModifier(_ keyCode: Int64) -> Bool {
        Self.optionKeyCodes.contains(keyCode) && keyCode != key.keyCode
    }

    /// Test seam. The rule is one line, but it is the line standing between a
    /// Right ⌥ user and a keyboard that eats their digits.
    func isPickerModifierForTesting(_ keyCode: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isPickerModifier(keyCode)
    }

    /// NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK — which side is actually
    /// down, rather than "some Option is down".
    static func optionIsDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let mask: UInt64 = keyCode == 58 ? 0x20 : 0x40
        return flags.rawValue & mask != 0
    }

    public init(key: HotkeyKey = .fn) {
        self.key = key
    }

    deinit {
        stop()
    }

    public func setKey(_ newKey: HotkeyKey) {
        lock.lock()
        // Same key ⇒ keep keyIsDown: resetting the edge detector while the user
        // is physically holding the key would swallow the coming key-up and
        // strand the session (reachable via any settings write re-applying
        // hotkey config mid-hold).
        if key != newKey {
            key = newKey
            keyIsDown = false
            // The picker modifier is defined relative to the dictation key, so
            // changing the key can change which Option is the modifier. A stale
            // "down" would then gate chords on a key nobody is holding.
            pickerModifierDown = false
        }
        lock.unlock()
    }

    public func setDoubleTapLockEnabled(_ enabled: Bool) {
        lock.lock()
        processor.doubleTapLockEnabled = enabled
        lock.unlock()
    }

    /// The user's Transforms in display order, each with its chord or nil.
    ///
    /// Empty means the Option gesture is inert, which is correct when every
    /// Transform has been deleted. Only chords that appear here are
    /// intercepted: ⌥7 with nothing on 7 must keep typing what ⌥7 has always
    /// typed, because swallowing a key for a gesture that does nothing breaks
    /// the keyboard.
    public func setWheelSlots(_ slots: [TransformShortcut?]) {
        lock.lock()
        processor.wheelSlots = slots
        boundSlots = Set(slots.compactMap { $0 })
        lock.unlock()
    }

    private var boundSlots: Set<TransformShortcut> = []

    /// The coordinator refused our .begin — the grammar's session is phantom.
    public func resetGrammar() {
        lock.lock()
        processor.reset()
        pickerModifierDown = false
        lock.unlock()
    }

    public func setExternalSessionActive(_ active: Bool) {
        lock.lock()
        externalSessionActive = active
        lock.unlock()
    }

    /// Starts the tap. Returns false (state == .permissionDenied) without Accessibility trust.
    /// Safe to call again after the user grants Accessibility (onboarding flow).
    @discardableResult
    public func start() -> Bool {
        if state == .permissionDenied {
            tapThread = nil
            state = .stopped
        }
        guard tapThread == nil else { return state == .running }

        let thread = Thread { [weak self] in
            self?.threadMain()
        }
        thread.name = "com.ammaar.jot.eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // Wait briefly for the thread to report tap creation success/failure.
        let deadline = Date().addingTimeInterval(2)
        while state == .stopped && Date() < deadline {
            usleep(10_000)
        }
        if state == .running {
            startHealthTimer()
        }
        return state == .running
    }

    public func stop() {
        doubleTapTimer?.cancel(); doubleTapTimer = nil
        wheelTimer?.cancel(); wheelTimer = nil
        healthTimer?.cancel(); healthTimer = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: false) }
        tapPort = nil
        runLoop = nil
        tapThread = nil
        state = .stopped
    }

    // MARK: - Tap thread

    private func threadMain() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<EventTapEngine>.fromOpaque(userInfo).takeUnretainedValue()
                return engine.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            Log.hotkey.error("EventTapEngine: tap creation failed — Accessibility not granted")
            state = .permissionDenied
            return
        }

        tapPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state = .running
        Log.hotkey.info("EventTapEngine: tap running (key=\(self.key.rawValue, privacy: .public))")
        CFRunLoopRun()
        Log.hotkey.info("EventTapEngine: run loop exited")
    }

    // MARK: - Event classification (tap thread)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Tap health: the OS silently disables taps that are slow or during login events.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapPort {
                CGEvent.tapEnable(tap: tapPort, enable: true)
                Log.hotkey.warning("EventTapEngine: tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public) — re-enabled")
                onTapRevived?()
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .flagsChanged:
            lock.lock()
            let configured = key
            guard keyCode == configured.keyCode else {
                // Option is the Transform picker's modifier. We only OBSERVE it:
                // the event always passes through, because Option is how every
                // accented character on a Mac gets typed and swallowing it would
                // break the keyboard for anyone mid-dictation.
                if isPickerModifier(keyCode) {
                    // Device-side bits, not `.maskAlternate`: the generic mask
                    // stays set while the opposite-side twin is held, which is
                    // the same trap audit L4 caught for the dictation key.
                    pickerModifierDown = Self.optionIsDown(keyCode: keyCode, flags: event.flags)
                    guard processor.isSessionActive else {
                        lock.unlock()
                        return Unmanaged.passUnretained(event)
                    }
                    let fx = processor.handle(pickerModifierDown ? .optionDown : .optionUp, at: now)
                    lock.unlock()
                    apply(fx)
                    return Unmanaged.passUnretained(event)
                }
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            let isDown = configured.isDown(in: event.flags)
            guard isDown != keyIsDown else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            keyIsDown = isDown
            let fx = processor.handle(isDown ? .hotkeyDown : .hotkeyUp, at: now)
            lock.unlock()
            apply(fx)
            return nil // consume: this key is ours

        case .keyDown:
            // Our own synthetic events (the InsertionEngine's ⌘V) are tagged with a
            // magic userData value and must never feed the grammar.
            guard event.getIntegerValueField(.eventSourceUserData) != SyntheticEventTag.magic else {
                return Unmanaged.passUnretained(event)
            }
            // Autorepeats are echoes, not intent: a key held down before the
            // session started must not abort it, and repeated Space/Esc must not
            // re-fire gestures (audit #14).
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return Unmanaged.passUnretained(event)
            }
            lock.lock()
            // Transform picker chords. Three conditions must hold together: a
            // session is active, the dictation key is physically held, and
            // Option is down. Outside that window nothing here changes, and
            // every other key still feeds .otherKeyDown and still aborts an
            // accidental chord exactly as before.
            //
            // These ARE consumed (return nil), unlike the Option modifier
            // itself: ⌥1 otherwise types "¡" into the app being dictated into.
            if processor.isSessionActive, pickerModifierDown {
                // Arrows are consumed ONLY while the wheel is actually up.
                // ⌥← / ⌥→ is standard word navigation; swallowing it for the
                // whole dictation would break editing in the app being
                // dictated into, for a gesture with nothing on screen to aim at.
                if Self.arrowKeyCodes.contains(keyCode), processor.picker != .closed {
                    // Left/up move back, right/down move forward — the wheel
                    // reads horizontally but both axes should work.
                    let delta = (keyCode == 123 || keyCode == 126) ? -1 : 1
                    let fx = processor.handle(.pickerMove(delta), at: now)
                    lock.unlock()
                    apply(fx)
                    return nil
                }
                if let slot = TransformShortcut.slot(forKeyCode: keyCode), boundSlots.contains(slot) {
                    let fx = processor.handle(.pickerSlot(slot), at: now)
                    lock.unlock()
                    apply(fx)
                    return nil
                }
            }
            // Space while the dictation key is physically held = hands-free lock.
            // Timing-free by construction — both keys are simply down together.
            if keyCode == 49, processor.isKeyHeld {
                let fx = processor.handle(.spaceLock, at: now)
                lock.unlock()
                apply(fx)
                return nil // the Space is a gesture, not typing
            }
            // Esc cancels grammar sessions AND externally-tracked ones
            // (in-flight transcription, UI-started hands-free).
            if keyCode == 53, externalSessionActive, !processor.isSessionActive {
                lock.unlock()
                onIntent?(.cancel)
                return nil
            }
            guard processor.isSessionActive else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            if keyCode == 53 { // Esc
                let fx = processor.handle(.escDown, at: now)
                lock.unlock()
                apply(fx)
                return nil // consume Esc only while dictating
            }
            let fx = processor.handle(.otherKeyDown, at: now)
            lock.unlock()
            apply(fx)
            return Unmanaged.passUnretained(event) // typing passes through

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func apply(_ fx: HotkeyProcessor.Effects) {
        // Timer lifecycle is confined to timerQueue — apply() runs on the tap
        // thread AND the timer queue, and unsynchronized DispatchSourceTimer
        // mutation is a crash (audit L17).
        if fx.disarmTimer || fx.armTimer != nil {
            let delay = fx.armTimer
            timerQueue.async { [weak self] in
                guard let self else { return }
                self.doubleTapTimer?.cancel()
                self.doubleTapTimer = nil
                guard let delay else { return }
                let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
                timer.schedule(deadline: .now() + delay)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let fx = self.processor.handle(.doubleTapTimeout, at: ProcessInfo.processInfo.systemUptime)
                    self.lock.unlock()
                    self.apply(fx)
                }
                timer.resume()
                self.doubleTapTimer = timer
            }
        }
        // Same lifecycle discipline as the double-tap timer: all mutation
        // confined to timerQueue, because apply() runs on the tap thread AND on
        // the timer queue, and unsynchronized DispatchSourceTimer mutation is a
        // crash (audit L17).
        if fx.disarmWheelTimer || fx.armWheelTimer != nil {
            let delay = fx.armWheelTimer
            timerQueue.async { [weak self] in
                guard let self else { return }
                self.wheelTimer?.cancel()
                self.wheelTimer = nil
                guard let delay else { return }
                let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
                timer.schedule(deadline: .now() + delay)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let fx = self.processor.handle(.wheelRevealTimeout, at: ProcessInfo.processInfo.systemUptime)
                    self.lock.unlock()
                    self.apply(fx)
                }
                timer.resume()
                self.wheelTimer = timer
            }
        }
        for intent in fx.intents {
            onIntent?(intent)
        }
    }

    // MARK: - Health polling

    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, let tapPort = self.tapPort else { return }
            if !CGEvent.tapIsEnabled(tap: tapPort) {
                CGEvent.tapEnable(tap: tapPort, enable: true)
                Log.hotkey.warning("EventTapEngine: health poll found tap disabled — re-enabled")
                self.onTapRevived?()
            }
        }
        timer.resume()
        healthTimer = timer
    }
}

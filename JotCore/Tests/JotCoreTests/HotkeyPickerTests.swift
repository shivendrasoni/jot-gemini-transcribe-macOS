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

import XCTest
@testable import JotCore

/// The Transform picker shares an event stream with the dictation grammar but
/// must not be able to disturb it. The riskiest thing in this feature is that
/// `⌥1` is, structurally, exactly the "another key went down" that already
/// means *abort this dictation as an accidental chord* — so several of these
/// tests exist purely to prove the two machines stay independent.
final class HotkeyPickerTests: XCTestCase {
    private func recording(slots: Int = 3) -> HotkeyProcessor {
        var processor = HotkeyProcessor()
        processor.wheelSlots = Array(TransformShortcut.slots.prefix(slots)).map { Optional($0) }
        _ = processor.handle(.hotkeyDown, at: 0)
        return processor
    }

    // MARK: Reveal

    func testOptionDownArmsTheTimerNotTheWheel() {
        var processor = recording()
        let fx = processor.handle(.optionDown, at: 1)

        XCTAssertEqual(fx.armWheelTimer, HotkeyTuning.wheelRevealDelay)
        XCTAssertEqual(processor.picker, .closed, "a fast ⌥1 must never flash the wheel")
        XCTAssertTrue(fx.intents.isEmpty)
    }

    func testWheelAppearsOnlyAfterTheRevealDelay() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        let fx = processor.handle(.wheelRevealTimeout, at: 1.25)

        XCTAssertEqual(processor.picker, .open(highlighted: 0))
        XCTAssertEqual(fx.intents, [.showTransformWheel(highlighted: 0)])
    }

    func testWheelDoesNotOpenWithNoSessionActive() {
        var processor = HotkeyProcessor()
        processor.wheelSlots = Array(TransformShortcut.slots.prefix(3)).map { Optional($0) }
        let fx = processor.handle(.optionDown, at: 1)

        XCTAssertNil(fx.armWheelTimer, "outside a dictation, Option is just Option")
        XCTAssertEqual(processor.picker, .closed)
    }

    func testWheelDoesNotOpenWithNoTransformsConfigured() {
        var processor = recording(slots: 0)
        let fx = processor.handle(.optionDown, at: 1)
        XCTAssertNil(fx.armWheelTimer, "an empty wheel is a lie about what is available")
    }

    /// A timeout that arrives after the user already let go must not raise a
    /// wheel nobody asked for.
    func testRevealTimeoutAfterOptionReleaseIsIgnored() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.optionUp, at: 1.1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)

        XCTAssertEqual(processor.picker, .closed)
    }

    // MARK: Arming

    func testDigitArmsImmediatelyWithoutTheWheel() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        let slot = TransformShortcut.slots[1]
        let fx = processor.handle(.pickerSlot(slot), at: 1.1)

        XCTAssertEqual(fx.intents, [.armTransform(1)])
        XCTAssertTrue(fx.disarmWheelTimer, "the wheel must not appear after the choice is made")
        XCTAssertEqual(processor.armedIndex, 1)
    }

    func testDigitWithTheWheelUpAlsoClosesIt() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        let slot = TransformShortcut.slots[1]
        let fx = processor.handle(.pickerSlot(slot), at: 1.3)

        XCTAssertEqual(fx.intents, [.armTransform(1), .dismissWheel])
        XCTAssertEqual(processor.picker, .closed)
    }

    func testSameSlotTwiceDisarms() {
        var processor = recording()
        let slot = TransformShortcut.slots[0]
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.pickerSlot(slot), at: 1.1)
        let fx = processor.handle(.pickerSlot(slot), at: 1.2)

        XCTAssertEqual(fx.intents, [.armTransform(nil)])
        XCTAssertNil(processor.armedIndex, "there must be no way to get stuck armed")
    }

    func testDifferentSlotReArms() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.pickerSlot(TransformShortcut.slots[0]), at: 1.1)
        let second = TransformShortcut.slots[2]
        let fx = processor.handle(.pickerSlot(second), at: 1.2)

        XCTAssertEqual(fx.intents, [.armTransform(2)])
        XCTAssertEqual(processor.armedIndex, 2)
    }

    func testReleasingOptionArmsTheHighlightedSlot() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        _ = processor.handle(.pickerMove(1), at: 1.3)
        let fx = processor.handle(.optionUp, at: 1.4)

        XCTAssertEqual(fx.intents, [.armTransform(1), .dismissWheel])
        XCTAssertEqual(processor.armedIndex, 1)
    }

    func testReleasingOptionWithoutTheWheelArmsNothing() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        let fx = processor.handle(.optionUp, at: 1.1)

        XCTAssertTrue(fx.intents.isEmpty)
        XCTAssertTrue(fx.disarmWheelTimer)
        XCTAssertNil(processor.armedIndex)
    }

    /// THE wheel bug. The highlight is a position in the USER'S list, so
    /// releasing over the third card must arm the third Transform — not
    /// whichever Transform happens to own ⌥3.
    func testReleasingOptionArmsByPositionNotByChord() {
        var processor = HotkeyProcessor()
        // Third Transform is bound to ⌥t; nothing is on ⌥3.
        processor.wheelSlots = [
            TransformShortcut.slots[0],
            TransformShortcut.slots[1],
            TransformShortcut.slot(forKeyCode: 17), // "t"
        ]
        _ = processor.handle(.hotkeyDown, at: 0)
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        _ = processor.handle(.pickerMove(2), at: 1.3)
        let fx = processor.handle(.optionUp, at: 1.4)

        XCTAssertEqual(fx.intents, [.armTransform(2), .dismissWheel])
    }

    /// A Transform with no chord bound is still reachable from the wheel —
    /// otherwise the wheel shows a card that cannot be chosen.
    func testWheelCanArmATransformWithNoShortcut() {
        var processor = HotkeyProcessor()
        processor.wheelSlots = [TransformShortcut.slots[0], nil]
        _ = processor.handle(.hotkeyDown, at: 0)
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        _ = processor.handle(.pickerMove(1), at: 1.3)
        let fx = processor.handle(.optionUp, at: 1.4)

        XCTAssertEqual(fx.intents, [.armTransform(1), .dismissWheel])
    }

    /// An unbound chord is not ours. It must not clear a Transform the user
    /// already chose, and the tap must let it through to be typed.
    func testUnboundSlotDoesNotDisarm() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.pickerSlot(TransformShortcut.slots[0]), at: 1.1)

        let unbound = TransformShortcut.slots[8] // ⌥9, nothing on it
        let fx = processor.handle(.pickerSlot(unbound), at: 1.2)

        XCTAssertTrue(fx.intents.isEmpty)
        XCTAssertEqual(processor.armedIndex, 0, "the earlier choice survives")
    }

    /// Reopening should show where you are, not snap back to the first card.
    func testWheelOpensOnTheAlreadyArmedSlot() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.pickerSlot(TransformShortcut.slots[2]), at: 1.1)
        _ = processor.handle(.optionUp, at: 1.2)

        _ = processor.handle(.optionDown, at: 2)
        _ = processor.handle(.wheelRevealTimeout, at: 2.25)
        XCTAssertEqual(processor.picker, .open(highlighted: 2))
    }

    // MARK: Movement

    func testArrowMovementClampsAtBothEnds() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)

        _ = processor.handle(.pickerMove(-5), at: 1.3)
        XCTAssertEqual(processor.picker, .open(highlighted: 0))

        _ = processor.handle(.pickerMove(99), at: 1.4)
        XCTAssertEqual(processor.picker, .open(highlighted: 2))
    }

    func testArrowMovementWithTheWheelClosedDoesNothing() {
        var processor = recording()
        let fx = processor.handle(.pickerMove(1), at: 1)
        XCTAssertTrue(fx.intents.isEmpty)
        XCTAssertEqual(processor.picker, .closed)
    }

    // MARK: Esc

    func testEscClosesTheWheelWithoutCancellingTheDictation() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        let fx = processor.handle(.escDown, at: 1.3)

        XCTAssertEqual(fx.intents, [.dismissWheel])
        XCTAssertEqual(processor.picker, .closed)
        XCTAssertTrue(processor.isSessionActive, "the dictation must survive backing out of a menu")
    }

    func testEscStillCancelsWhenTheWheelIsClosed() {
        var processor = recording()
        let fx = processor.handle(.escDown, at: 1)
        XCTAssertEqual(fx.intents, [.cancel])
    }

    /// Esc closes the wheel; a SECOND Esc then cancels, as it always did.
    func testSecondEscCancelsAfterTheWheelIsClosed() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        _ = processor.handle(.escDown, at: 1.3)
        let fx = processor.handle(.escDown, at: 1.4)
        XCTAssertEqual(fx.intents, [.cancel])
    }

    // MARK: Independence from the dictation grammar

    /// THE test. `⌥1` is structurally the same event that aborts an accidental
    /// chord, and must never be mistaken for one.
    func testPickerKeysNeverAbortAsAnAccidentalChord() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 0.1)
        let fx = processor.handle(.pickerSlot(TransformShortcut.slots[0]), at: 0.2)

        XCTAssertFalse(fx.intents.contains(.abortAccidental))
        XCTAssertTrue(processor.isSessionActive)
    }

    func testOptionDoesNotDisturbTheHoldClassification() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 0.1)
        _ = processor.handle(.pickerSlot(TransformShortcut.slots[0]), at: 0.2)
        _ = processor.handle(.optionUp, at: 0.3)

        let fx = processor.handle(.hotkeyUp, at: 0.5)
        XCTAssertEqual(fx.intents, [.finalize], "a held key still finalizes on release")
    }

    func testSpaceLockStillWorksWithATransformArmed() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 0.1)
        _ = processor.handle(.pickerSlot(TransformShortcut.slots[0]), at: 0.2)
        _ = processor.handle(.optionUp, at: 0.3)

        let fx = processor.handle(.spaceLock, at: 0.4)
        XCTAssertEqual(fx.intents, [.lockIn])
        XCTAssertEqual(processor.armedIndex, 0, "the arming survives the lock")
    }

    // MARK: Lifecycle

    func testWheelAndArmingClearWhenTheSessionEnds() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        _ = processor.handle(.pickerSlot(TransformShortcut.slots[0]), at: 1.3)
        _ = processor.handle(.hotkeyUp, at: 2)

        XCTAssertEqual(processor.picker, .closed)
        XCTAssertNil(processor.armedIndex, "the next dictation must not inherit this one's Transform")
    }

    /// Ending a dictation with the wheel still up must take it OFF SCREEN, not
    /// merely forget about it internally.
    func testEndingADictationDismissesAnOpenWheel() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        XCTAssertEqual(processor.picker, .open(highlighted: 0))

        let fx = processor.handle(.hotkeyUp, at: 2)

        XCTAssertTrue(fx.intents.contains(.dismissWheel), "the wheel is on screen; something must take it down")
        XCTAssertTrue(fx.intents.contains(.finalize), "and the dictation still finalizes")
        XCTAssertTrue(fx.disarmWheelTimer)
    }

    func testCancellingWithTheWheelUpAlsoDismissesIt() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        // Esc closes the wheel first, so a SECOND Esc is the cancel — and by
        // then the wheel is already down.
        _ = processor.handle(.escDown, at: 1.3)
        let fx = processor.handle(.escDown, at: 1.4)

        XCTAssertEqual(fx.intents, [.cancel])
        XCTAssertEqual(processor.picker, .closed)
    }

    /// An accidental chord kills a young session; the wheel must go with it.
    func testAccidentalChordDismissesAnOpenWheel() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 0.1)
        _ = processor.handle(.wheelRevealTimeout, at: 0.35)
        let fx = processor.handle(.otherKeyDown, at: 0.5)

        XCTAssertTrue(fx.intents.contains(.abortAccidental))
        XCTAssertTrue(fx.intents.contains(.dismissWheel))
    }

    func testArmingClearsOnCancel() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.pickerSlot(TransformShortcut.slots[0]), at: 1.1)
        _ = processor.handle(.escDown, at: 1.2)

        XCTAssertNil(processor.armedIndex)
    }

    func testResetClearsThePicker() {
        var processor = recording()
        _ = processor.handle(.optionDown, at: 1)
        _ = processor.handle(.wheelRevealTimeout, at: 1.25)
        processor.reset()

        XCTAssertEqual(processor.picker, .closed)
        XCTAssertNil(processor.armedIndex)
    }
}

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

import CoreGraphics
import XCTest
@testable import JotCore

/// Which Option key is down, and whether it is the one doing the dictating.
///
/// This exists because **Right ⌥ is a selectable dictation key**. Holding it
/// sets the generic `.maskAlternate` flag for the entire dictation, so a
/// feature that gates on that flag would hijack every digit and arrow that user
/// types for the whole hold — the same trap audit L4 caught for the dictation
/// key itself, arriving by a different door.
final class TransformModifierTests: XCTestCase {
    /// NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK.
    private let leftDown = CGEventFlags(rawValue: 0x20)
    private let rightDown = CGEventFlags(rawValue: 0x40)
    private let bothDown = CGEventFlags(rawValue: 0x60)
    /// The generic mask, with no side bit — what a flags test alone would see.
    private let genericOnly = CGEventFlags.maskAlternate

    func testReadsTheSideThatIsActuallyDown() {
        XCTAssertTrue(EventTapEngine.optionIsDown(keyCode: 58, flags: leftDown))
        XCTAssertFalse(EventTapEngine.optionIsDown(keyCode: 61, flags: leftDown))

        XCTAssertTrue(EventTapEngine.optionIsDown(keyCode: 61, flags: rightDown))
        XCTAssertFalse(EventTapEngine.optionIsDown(keyCode: 58, flags: rightDown))
    }

    /// The generic mask stays set while the opposite twin is held, which is
    /// exactly how a release gets missed.
    func testTheGenericMaskAloneSaysNothingAboutEitherSide() {
        XCTAssertFalse(EventTapEngine.optionIsDown(keyCode: 58, flags: genericOnly))
        XCTAssertFalse(EventTapEngine.optionIsDown(keyCode: 61, flags: genericOnly))
    }

    func testBothSidesCanBeDownAtOnce() {
        XCTAssertTrue(EventTapEngine.optionIsDown(keyCode: 58, flags: bothDown))
        XCTAssertTrue(EventTapEngine.optionIsDown(keyCode: 61, flags: bothDown))
    }

    /// Right ⌥ users keep the feature: Left ⌥ becomes the picker modifier, and
    /// the key doing the dictating is never also the key opening the wheel.
    func testTheDictationKeyIsNeverThePickerModifier() {
        let engine = EventTapEngine(key: .rightOption)
        XCTAssertFalse(engine.isPickerModifierForTesting(61), "Right ⌥ is dictating; it cannot also pick")
        XCTAssertTrue(engine.isPickerModifierForTesting(58), "Left ⌥ still opens the wheel")
    }

    func testWithFnDictatingBothOptionsArePickerModifiers() {
        let engine = EventTapEngine(key: .fn)
        XCTAssertTrue(engine.isPickerModifierForTesting(58))
        XCTAssertTrue(engine.isPickerModifierForTesting(61))
    }

    func testNonOptionKeysAreNeverThePickerModifier() {
        let engine = EventTapEngine(key: .fn)
        for keyCode: Int64 in [63, 54, 62, 49, 53, 18] {
            XCTAssertFalse(engine.isPickerModifierForTesting(keyCode), "keycode \(keyCode)")
        }
    }

    /// Changing the dictation key changes which Option is the modifier.
    func testSwitchingToRightOptionReleasesItAsAModifier() {
        let engine = EventTapEngine(key: .fn)
        XCTAssertTrue(engine.isPickerModifierForTesting(61))
        engine.setKey(.rightOption)
        XCTAssertFalse(engine.isPickerModifierForTesting(61))
        XCTAssertTrue(engine.isPickerModifierForTesting(58))
    }
}

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

/// The store's job is to make two things impossible: a Transform list that has
/// drifted from the shipped defaults with no way back, and two Transforms
/// claiming one keyboard chord.
final class TransformStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: TransformStore!

    override func setUp() {
        super.setUp()
        suiteName = "transform-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = TransformStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSeedsBuiltInsWhenKeyAbsent() {
        let seeded = store.transforms()
        XCTAssertEqual(seeded.map(\.name), ["Polish", "Prompt Engineer", "Simplify"])
        XCTAssertTrue(seeded.allSatisfy(\.isBuiltIn))
        XCTAssertFalse(seeded.contains { $0.prompt.isEmpty }, "a shipped Transform with no prompt is a dead card")
    }

    func testBuiltInsHaveDistinctShortcuts() {
        let shortcuts = store.transforms().compactMap(\.shortcut)
        XCTAssertEqual(shortcuts.count, 3)
        XCTAssertEqual(Set(shortcuts).count, 3)
    }

    /// Reset is "delete the key", so there is exactly ONE copy of the seed list
    /// and it cannot drift from the one `transforms()` falls back to.
    func testResetRestoresBuiltInsAfterEdits() {
        var edited = store.transforms()
        edited[0].name = "Renamed"
        store.save(edited)
        XCTAssertEqual(store.transforms()[0].name, "Renamed")

        store.resetToDefaults()
        XCTAssertEqual(store.transforms()[0].name, "Polish")
    }

    /// Two Transforms must never hold one chord: which one fired would depend on
    /// array order, which is invisible to the user and stable enough in testing
    /// to ship broken.
    func testAssigningAShortcutStealsItFromTheOtherTransform() {
        let slot = TransformShortcut.slots[0] // ⌥1
        var all = store.transforms()
        XCTAssertEqual(all[0].shortcut, slot)

        all[1].shortcut = slot
        store.save(all)

        let after = store.transforms()
        XCTAssertNil(after[0].shortcut, "the earlier claim must be released")
        XCTAssertEqual(after[1].shortcut, slot)
        XCTAssertEqual(store.transform(forShortcut: slot)?.name, "Prompt Engineer")
    }

    func testSaveEnforcesTheCap() {
        let extras = (0..<30).map { index in
            Transform(name: "T\(index)", summary: "", prompt: "p", shortcut: nil, isBuiltIn: false, order: index)
        }
        store.save(extras)
        XCTAssertEqual(store.transforms().count, TransformStore.maxTransforms)
    }

    func testRemoveDropsOnlyThatTransform() {
        let target = store.transforms()[1]
        store.remove(id: target.id)
        XCTAssertEqual(store.transforms().count, 2)
        XCTAssertNil(store.transform(id: target.id))
    }

    func testUpsertReplacesInPlaceWithoutReordering() {
        var target = store.transforms()[1]
        target.name = "Edited"
        store.upsert(target)

        let after = store.transforms()
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[1].name, "Edited")
        XCTAssertEqual(after.map(\.id), store.transforms().map(\.id))
    }

    func testUpsertAppendsAnUnknownTransform() {
        let fresh = Transform(name: "Mine", summary: "", prompt: "p", shortcut: nil, isBuiltIn: false, order: 99)
        store.upsert(fresh)
        XCTAssertEqual(store.transforms().count, 4)
        XCTAssertEqual(store.transforms().last?.name, "Mine")
    }

    /// A corrupt blob must not take the feature down with it — the user gets the
    /// defaults back rather than an empty grid and no explanation.
    func testCorruptStoredDataFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: "transforms")
        XCTAssertEqual(store.transforms().map(\.name), ["Polish", "Prompt Engineer", "Simplify"])
    }

    /// Saving an empty list is a legitimate "I deleted them all" and must stick,
    /// or the user can never get rid of a Transform they do not want.
    func testEmptyListIsPersistedRatherThanReseeded() {
        store.save([])
        XCTAssertTrue(store.transforms().isEmpty)
    }

    func testSlotsCoverDigitsThenLetters() {
        XCTAssertEqual(TransformShortcut.slots.count, 35)
        XCTAssertEqual(TransformShortcut.slots.prefix(9).map(\.label), ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertEqual(TransformShortcut.slots[9].label, "a")
        XCTAssertEqual(Set(TransformShortcut.slots.map(\.keyCode)).count, 35)
    }

    func testSlotLookupByKeyCodeRoundTrips() {
        for slot in TransformShortcut.slots {
            XCTAssertEqual(TransformShortcut.slot(forKeyCode: slot.keyCode), slot)
        }
        XCTAssertNil(TransformShortcut.slot(forKeyCode: 53), "Esc is not a slot")
    }
}

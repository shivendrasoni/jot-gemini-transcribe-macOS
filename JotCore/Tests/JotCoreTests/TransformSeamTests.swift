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

/// The four seams Transforms needed cut into existing types. Each one is
/// additive and defaulted, because a field that is not optional here is a field
/// that breaks every call site and every meta.json ever written.
final class TransformSeamTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "seam-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Without an isolatable store, every settings-touching test races the
    /// developer's own preferences.
    func testSettingsStoreCanBeIsolatedToASuite() {
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.formattingPolicy.cleanupPass, "the tone pass ships off")

        settings.setSmartCleanupPass(true)
        XCTAssertTrue(SettingsStore(defaults: defaults).formattingPolicy.cleanupPass)
    }

    func testDictionaryStoreCanBeIsolatedToASuite() {
        let dictionary = DictionaryStore(defaults: defaults)
        XCTAssertTrue(dictionary.entries().isEmpty)
        XCTAssertTrue(dictionary.add(term: "Kubernetes"))
        XCTAssertEqual(DictionaryStore(defaults: defaults).vocabulary(), ["Kubernetes"])
    }

    // MARK: The tone pass stands aside for a Transform

    private func policy(cleanupPass: Bool) -> SettingsStore.FormattingPolicy {
        SettingsStore.FormattingPolicy(nativeSmart: true, cleanupPass: cleanupPass)
    }

    private func context(armed: UUID?) -> DictationContext {
        var context = DictationContext()
        context.armedTransformID = armed
        return context
    }

    /// The whole point of "a Transform replaces the cleanup pass": with one
    /// armed, the tone pass must not also run and spend a second round trip on
    /// output the Transform immediately overwrites.
    func testArmedTransformSuppressesTheCleanupPass() {
        XCTAssertFalse(
            GeminiTranscriptionService.shouldRunCleanupPass(
                policy: policy(cleanupPass: true), context: context(armed: UUID())
            )
        )
    }

    func testCleanupPassStillRunsWithNothingArmed() {
        XCTAssertTrue(
            GeminiTranscriptionService.shouldRunCleanupPass(
                policy: policy(cleanupPass: true), context: context(armed: nil)
            )
        )
    }

    /// Arming a Transform must not turn the tone pass ON for someone who has it
    /// switched off — the suppression only ever subtracts.
    func testArmingDoesNotEnableACleanupPassThatWasOff() {
        XCTAssertFalse(
            GeminiTranscriptionService.shouldRunCleanupPass(
                policy: policy(cleanupPass: false), context: context(armed: UUID())
            )
        )
        XCTAssertFalse(
            GeminiTranscriptionService.shouldRunCleanupPass(
                policy: policy(cleanupPass: false), context: context(armed: nil)
            )
        )
    }

    func testTranscriptionResultDefaultsToNoTransformNote() {
        let result = TranscriptionResult(rawTranscript: "a", cleanedTranscript: "a", modelID: "m")
        XCTAssertNil(result.transformNote)
    }

    func testDictationContextDefaultsToNoArmedTransform() {
        XCTAssertNil(DictationContext().armedTransformID)
    }

    func testTransformNoteReportsNameAndOutcome() {
        XCTAssertTrue(TransformNote.applied("Polish").didApply)
        XCTAssertEqual(TransformNote.applied("Polish").transformName, "Polish")
        XCTAssertFalse(TransformNote.skipped("Polish", reason: "timeout").didApply)
        XCTAssertEqual(TransformNote.skipped("Polish", reason: "timeout").transformName, "Polish")
    }

    /// meta.json written before Transforms existed must still decode, or the
    /// first launch after upgrading loses the user's History.
    func testSessionMetaDecodesWithoutTransformFields() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":"2026-09-16T00:00:00Z","status":"inserted","gapMarkers":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(SessionMeta.self, from: Data(json.utf8))
        XCTAssertNil(meta.transformName)
        XCTAssertNil(meta.transformApplied)
    }

    func testSessionMetaRoundTripsTransformFields() throws {
        var meta = SessionMeta(id: UUID(), startedAt: Date(), status: .inserted)
        meta.transformName = "Polish"
        meta.transformApplied = false

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionMeta.self, from: try encoder.encode(meta))

        XCTAssertEqual(decoded.transformName, "Polish")
        XCTAssertEqual(decoded.transformApplied, false)
    }
}

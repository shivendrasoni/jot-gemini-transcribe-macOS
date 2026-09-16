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

/// The decorator has exactly one safety property, and most of this file exists
/// to pin it: **it can return the transformed text or the inner result, and
/// there is no third outcome.** A Transform failing is never a dictation
/// failing. Every way the model can misbehave — throwing, timing out, refusing,
/// running away, coming back empty — has to land on the untransformed
/// transcript with the user told what happened.
final class TransformingTranscriptionServiceTests: XCTestCase {

    // MARK: Fakes

    private struct FakeInner: TranscriptionServicing {
        var result = TranscriptionResult(rawTranscript: "raw text", cleanedTranscript: "clean text", modelID: "inner")
        var error: TranscriptionError?
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            if let error { throw error }
            return result
        }
    }

    private final class FakeModel: TransformTexting, @unchecked Sendable {
        var output: String
        var error: Error?
        private let lock = NSLock()
        private var prompts: [String] = []

        init(output: String = "TRANSFORMED", error: Error? = nil) {
            self.output = output
            self.error = error
        }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return prompts.count }
        var lastPrompt: String? { lock.lock(); defer { lock.unlock() }; return prompts.last }

        func transform(prompt: String, deadline: TimeInterval) async throws -> String {
            lock.lock(); prompts.append(prompt); lock.unlock()
            if let error { throw error }
            return output
        }
    }

    // MARK: Fixtures

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: TransformStore!
    private var polishID: UUID!

    override func setUp() {
        super.setUp()
        suiteName = "transforming-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = TransformStore(defaults: defaults)
        polishID = store.transforms()[0].id
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func make(inner: FakeInner = FakeInner(), model: FakeModel = FakeModel()) -> TransformingTranscriptionService {
        TransformingTranscriptionService(
            inner: inner,
            model: model,
            store: store,
            dictionary: DictionaryStore(defaults: defaults)
        )
    }

    private func run(
        _ service: TransformingTranscriptionService,
        armed id: UUID?
    ) async throws -> TranscriptionResult {
        var context = DictationContext()
        context.armedTransformID = id
        return try await service.transcribe(
            audioURL: URL(fileURLWithPath: "/dev/null"), durationSeconds: 1, context: context
        )
    }

    // MARK: The default path

    func testPassesThroughUntouchedWhenNothingArmed() async throws {
        let model = FakeModel()
        let result = try await run(make(model: model), armed: nil)

        XCTAssertEqual(result.cleanedTranscript, "clean text")
        XCTAssertEqual(result.modelID, "inner")
        XCTAssertNil(result.transformNote)
        XCTAssertEqual(model.callCount, 0, "the default path must cost nothing")
    }

    // MARK: The happy path

    func testAppliesTheArmedTransform() async throws {
        let result = try await run(make(), armed: polishID)

        XCTAssertEqual(result.cleanedTranscript, "TRANSFORMED")
        XCTAssertEqual(result.rawTranscript, "raw text", "the raw transcript is still the raw transcript")
        XCTAssertTrue(result.modelID.hasSuffix("+transform"))
        XCTAssertEqual(result.transformNote, .applied("Polish"))
    }

    func testSendsTheTransformsOwnPromptAndTheCleanedTranscript() async throws {
        let model = FakeModel()
        _ = try await run(make(model: model), armed: polishID)

        let prompt = try XCTUnwrap(model.lastPrompt)
        XCTAssertTrue(prompt.contains("Rewrite the dictated text as clean, polished prose."))
        XCTAssertTrue(prompt.contains("clean text"), "the transform sees the smart transcript, not the raw one")
    }

    // MARK: Every way it can fail

    func testModelThrowingReturnsTheInnerResultAndNeverThrows() async throws {
        let model = FakeModel(output: "", error: TranscriptionError.timeout)
        let result = try await run(make(model: model), armed: polishID)

        XCTAssertEqual(result.cleanedTranscript, "clean text")
        XCTAssertEqual(result.transformNote, .skipped("Polish", reason: "timeout"))
    }

    func testOfflineIsReportedAsOfflineNotAsAGenericFailure() async throws {
        let model = FakeModel(output: "", error: TranscriptionError.offline)
        let result = try await run(make(model: model), armed: polishID)
        XCTAssertEqual(result.transformNote, .skipped("Polish", reason: "offline"))
    }

    func testGateRejectionReturnsTheInnerResult() async throws {
        let model = FakeModel(output: "As an AI language model, I cannot do that.")
        let result = try await run(make(model: model), armed: polishID)

        XCTAssertEqual(result.cleanedTranscript, "clean text")
        XCTAssertEqual(result.transformNote, .skipped("Polish", reason: "refusal"))
    }

    func testEmptyModelOutputReturnsTheInnerResult() async throws {
        let model = FakeModel(output: "   ")
        let result = try await run(make(model: model), armed: polishID)

        XCTAssertEqual(result.cleanedTranscript, "clean text")
        XCTAssertEqual(result.transformNote, .skipped("Polish", reason: "empty_output"))
    }

    /// A Transform deleted between arming and finalizing must not strand the
    /// dictation, and must not claim a Transform ran.
    func testUnknownTransformIDPassesThrough() async throws {
        let model = FakeModel()
        let result = try await run(make(model: model), armed: UUID())

        XCTAssertEqual(result.cleanedTranscript, "clean text")
        XCTAssertNil(result.transformNote)
        XCTAssertEqual(model.callCount, 0)
    }

    /// A Transform whose prompt was emptied in the editor is a card that does
    /// nothing — do not spend a round trip discovering that.
    func testUnusableTransformIsNotSent() async throws {
        var broken = store.transforms()[0]
        broken.prompt = "   "
        store.upsert(broken)

        let model = FakeModel()
        let result = try await run(make(model: model), armed: polishID)

        XCTAssertEqual(model.callCount, 0)
        XCTAssertEqual(result.transformNote, .skipped("Polish", reason: "empty_prompt"))
    }

    /// Inner errors are the DICTATION's errors. Swallowing one here would turn
    /// a retryable failure into a silent empty insert.
    func testInnerErrorsPropagateUnchanged() async {
        let inner = FakeInner(error: .emptyTranscript)
        do {
            _ = try await run(make(inner: inner), armed: polishID)
            XCTFail("expected the inner error to propagate")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .emptyTranscript)
        }
    }

    // MARK: Interaction with the rest of the pipeline

    /// The Dictionary's explicit wrong→right rules are a HARD guarantee on
    /// every path (audit L9) — including through a Transform.
    func testDictionaryRulesStillApplyToTransformedText() async throws {
        DictionaryStore(defaults: defaults).save([
            DictionaryEntry(term: "Kubernetes", misspelling: "TRANSFORMED")
        ])
        let result = try await run(make(), armed: polishID)
        XCTAssertEqual(result.cleanedTranscript, "Kubernetes")
    }

    /// …and when the Transform is skipped, the inner result must keep whatever
    /// the inner service already did to it, not be re-processed.
    func testSkippedTransformDoesNotReprocessTheInnerResult() async throws {
        let model = FakeModel(output: "", error: TranscriptionError.timeout)
        let result = try await run(make(model: model), armed: polishID)
        XCTAssertEqual(result.cleanedTranscript, "clean text")
        XCTAssertEqual(result.modelID, "inner", "a skipped transform must not claim credit in the model ID")
    }

    func testVocabularyRidesAlongWithTheTransform() async throws {
        DictionaryStore(defaults: defaults).save([DictionaryEntry(term: "Kubernetes")])
        let model = FakeModel()
        _ = try await run(make(model: model), armed: polishID)
        XCTAssertTrue(try XCTUnwrap(model.lastPrompt).contains("Kubernetes"))
    }
}

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

/// The seam through which a Transform reaches a model.
///
/// Narrow on purpose: one text in, one text out. The decorator below never
/// needs to know about endpoints, model names or API keys, and every failure
/// mode can be driven in a test with no network.
public protocol TransformTexting: Sendable {
    func transform(prompt: String, deadline: TimeInterval) async throws -> String
}

extension GeminiClient: TransformTexting {
    public func transform(prompt: String, deadline: TimeInterval) async throws -> String {
        let settings = SettingsStore()
        let config = settings.geminiConfig
        return try await cleanup(
            prompt: prompt, model: config.cleanupModel, endpoint: config.endpoint, deadline: deadline
        )
    }
}

/// Runs the armed Transform over a finished transcript, or gets out of the way.
///
///   CAF → [inner service: FLAC → transcribe → optional tone pass] → transcript
///       → [armed?] → Transform prompt → loose gate → ReplacementEngine → text
///
/// **The invariant that makes this safe: this type never throws its own error.**
/// It returns the transformed text or it returns the inner result, and there is
/// no third outcome. A Transform failing is never a dictation failing — the
/// same doctrine as `cleanupOrFallback`, where a deadline miss costs the polish
/// and never the words.
///
/// Errors from the INNER service are a different matter and propagate
/// untouched: those are the dictation's own failures, and the coordinator's
/// classification of them (offline queues, empty-transcript silence, retryable
/// vs terminal) must not be disturbed by a decorator.
public struct TransformingTranscriptionService: TranscriptionServicing {
    private let inner: TranscriptionServicing
    private let model: TransformTexting
    private let store: TransformStore
    private let dictionary: DictionaryStore

    /// Six seconds, not the tone pass's 1.5.
    ///
    /// The tone pass is a light touch-up whose whole justification is that it is
    /// nearly free, so a tight cap is right for it. A Transform is a rewrite the
    /// user explicitly asked for by name, and Prompt Engineer emitting a
    /// structured block takes longer than a polish. Timing that out at 1.5s
    /// would make the built-in fail more often than it works.
    public static let transformDeadline: TimeInterval = 6.0

    public init(
        inner: TranscriptionServicing,
        model: TransformTexting,
        store: TransformStore = TransformStore(),
        dictionary: DictionaryStore = DictionaryStore()
    ) {
        self.inner = inner
        self.model = model
        self.store = store
        self.dictionary = dictionary
    }

    public func transcribe(
        audioURL: URL, durationSeconds: Double, context: DictationContext
    ) async throws -> TranscriptionResult {
        let result = try await inner.transcribe(
            audioURL: audioURL, durationSeconds: durationSeconds, context: context
        )

        // Nothing armed: byte-identical passthrough. Almost every dictation
        // takes this path and it must cost nothing.
        guard let id = context.armedTransformID else { return result }

        // The Transform can be deleted between arming and finalizing. That is
        // not a failure worth telling the user about — there is no name left to
        // put in the message.
        guard let transform = store.transform(id: id) else {
            Log.transcription.info("armed transform no longer exists — inserting as dictated")
            return result
        }
        guard transform.isUsable else {
            Log.transcription.info("transform \(transform.name, privacy: .public) has no prompt — inserting as dictated")
            return skipped(result, transform, reason: "empty_prompt")
        }

        let prompt = TransformPromptV1.prompt(
            transform: transform,
            transcript: result.cleanedTranscript,
            vocabulary: dictionary.sanitizedVocabulary(),
            spellings: dictionary.spellings()
        )

        let response: String
        do {
            response = try await model.transform(prompt: prompt, deadline: Self.transformDeadline)
        } catch {
            Log.transcription.info("transform \(transform.name, privacy: .public) unavailable (\(String(describing: error), privacy: .public)) — inserting as dictated")
            return skipped(result, transform, reason: Self.reason(for: error))
        }

        let verdict = TransformGate.validate(output: response, transcript: result.cleanedTranscript)
        guard verdict.accepted else {
            Log.transcription.warning("transform \(transform.name, privacy: .public) REJECTED (\(verdict.reason ?? "?", privacy: .public)) — inserting as dictated")
            return skipped(result, transform, reason: verdict.reason ?? "rejected")
        }

        var applied = result
        // The dictionary's hard guarantee holds on every path (audit L9),
        // including through a Transform.
        applied.cleanedTranscript = ReplacementEngine.apply(dictionary.replacementRules(), to: verdict.stripped)
        applied.modelID = "\(result.modelID)+transform"
        applied.transformNote = .applied(transform.name)
        return applied
    }

    /// Returns the inner result untouched apart from the note. Untouched
    /// matters: re-running the dictionary rules here would double-apply them,
    /// and claiming "+transform" in the model ID would make History lie.
    private func skipped(_ result: TranscriptionResult, _ transform: Transform, reason: String) -> TranscriptionResult {
        var skipped = result
        skipped.transformNote = .skipped(transform.name, reason: reason)
        return skipped
    }

    /// A short machine reason for the note. The pill shows the Transform's name
    /// and "didn't run"; this is what lands in History and the log.
    static func reason(for error: Error) -> String {
        switch error as? TranscriptionError {
        case .timeout: return "timeout"
        case .offline: return "offline"
        case .auth: return "auth"
        case .rateLimitedDaily, .rateLimitedTransient: return "rate_limit"
        case .modelUnavailable: return "model"
        case .safetyBlocked: return "safety"
        case .badRequest: return "bad_request"
        case .network: return "network"
        case .emptyTranscript: return "empty_output"
        case nil: return "unknown"
        }
    }
}

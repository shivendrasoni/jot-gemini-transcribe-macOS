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
import Foundation

/// Transcription seam. M3 provides the Gemini implementation; tests use fakes.
public protocol TranscriptionServicing: Sendable {
    /// Returns (rawTranscript, cleanedTranscript). Throws TranscriptionError.
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult
}

public struct TranscriptionResult: Equatable, Sendable {
    public var rawTranscript: String
    public var cleanedTranscript: String
    public var modelID: String
    /// What the armed Transform did, if one was armed. The user asked for a
    /// named thing by name, so a Transform that quietly does nothing is worse
    /// than one that visibly fails — they would ship the untransformed text
    /// believing it was transformed.
    public var transformNote: TransformNote?

    public init(
        rawTranscript: String,
        cleanedTranscript: String,
        modelID: String,
        transformNote: TransformNote? = nil
    ) {
        self.rawTranscript = rawTranscript
        self.cleanedTranscript = cleanedTranscript
        self.modelID = modelID
        self.transformNote = transformNote
    }
}

/// The outcome of an armed Transform, carried back to the HUD and History.
public enum TransformNote: Equatable, Sendable {
    case applied(String)
    /// Name plus a short machine reason (`timeout`, `ai_selfreference`, …).
    case skipped(String, reason: String)

    public var transformName: String {
        switch self {
        case .applied(let name): return name
        case .skipped(let name, _): return name
        }
    }

    public var didApply: Bool {
        if case .applied = self { return true }
        return false
    }
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case offline
    case network(String)
    /// Permanent request failure (400) — retrying is pointless (audit #3).
    case badRequest(String)
    /// 401 — the key itself was rejected.
    case auth
    /// 403/404 — key is fine but this model is gated, renamed, or unknown.
    /// Distinct from .auth: "fix your key" is the WRONG advice here.
    case modelUnavailable(model: String, detail: String?)
    /// 429 that is a real daily/hard quota.
    case rateLimitedDaily
    /// 429 per-minute throttle — clears on its own; retryable.
    case rateLimitedTransient
    case timeout
    case emptyTranscript
    case safetyBlocked
}

/// Snapshot of where the user was dictating, captured at hotkey-down.
public struct DictationContext: Equatable, Sendable {
    public var targetAppBundleID: String?
    public var targetAppName: String?
    public var targetPID: pid_t?
    /// The Transform armed for THIS dictation, if any.
    ///
    /// Lives on the context rather than in a store lookup at transcribe time
    /// because it is a property of one recording, not of the app: arming ⌥1
    /// mid-sentence must not retroactively change a dictation already in flight.
    public var armedTransformID: UUID?

    public init(
        targetAppBundleID: String? = nil,
        targetAppName: String? = nil,
        targetPID: pid_t? = nil,
        armedTransformID: UUID? = nil
    ) {
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        self.targetPID = targetPID
        self.armedTransformID = armedTransformID
    }
}

/// Insertion seam. M4 provides the AX/paste ladder; tests use fakes.
public protocol TextInserting {
    @MainActor func insert(_ text: String, context: DictationContext) async -> InsertionOutcome
}

public enum InsertionOutcome: Equatable, Sendable {
    case inserted
    case frontmostChanged
    case fellBackToClipboard
    /// Secure input active — text stays in History only, never on the clipboard.
    case blockedSecureField
}

// MARK: - M2 stubs (replaced in M3/M4)

/// Until the Gemini client lands, "transcription" echoes a stub instantly.
public struct StubTranscriptionService: TranscriptionServicing {
    public init() {}
    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let text = String(format: "(recorded %.1fs — transcription arrives in M3)", durationSeconds)
        return TranscriptionResult(rawTranscript: text, cleanedTranscript: text, modelID: "stub")
    }
}

/// Until the insertion ladder lands, put the text on the clipboard.
public struct StubClipboardInserter: TextInserting {
    public init() {}
    @MainActor public func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return .fellBackToClipboard
    }
}

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

/// The "never insert garbage" gate for Transform output.
///
/// `ValidationGate` catches an answering model by measuring how far the cleaned
/// text drifted from the raw transcript — containment and trigram similarity.
/// That measure is unusable here: a Transform's job IS to diverge, and Prompt
/// Engineer would trip the strict gate on every single run.
///
/// What remains is the set of outcomes that are never legitimate however the
/// prompt was written: nothing came back, the model talked about itself, it ran
/// away, or it read the instructions out loud instead of following them. On any
/// of them the caller inserts the untransformed transcript and says so.
public enum TransformGate {
    public struct Verdict: Equatable, Sendable {
        public let accepted: Bool
        public let reason: String?
        /// The artifact-stripped text. The caller inserts THIS, not the raw
        /// response — otherwise a code-fenced answer reaches the cursor wearing
        /// its fences.
        public let stripped: String

        static func ok(_ stripped: String) -> Verdict {
            Verdict(accepted: true, reason: nil, stripped: stripped)
        }

        static func fail(_ reason: String, _ stripped: String) -> Verdict {
            Verdict(accepted: false, reason: reason, stripped: stripped)
        }
    }

    /// Generous on purpose. Prompt Engineer turns one spoken sentence into a
    /// structured block, which is routinely 5-6x. This catches the degenerate
    /// repeat-until-token-limit failure, not ambitious rewriting.
    public static let maxExpansionRatio = 8.0

    /// Below this, a ratio says nothing — "fix it" legitimately becomes a
    /// paragraph. Applying the ceiling here would reject the shortest, most
    /// common commands.
    public static let minTranscriptForRatio = 16

    public static func validate(output: String, transcript: String) -> Verdict {
        let stripped = ValidationGate.stripArtifacts(output)

        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail("empty_output", stripped)
        }
        if isRefusal(stripped) {
            return .fail("refusal", stripped)
        }
        if stripped.range(of: instructionTell, options: .caseInsensitive) != nil {
            return .fail("instruction_echo", stripped)
        }
        if transcript.count >= minTranscriptForRatio,
           Double(stripped.count) > expansionCeiling(forTranscript: transcript) {
            return .fail("runaway_length", stripped)
        }
        return .ok(stripped)
    }

    /// A model declining the job, which always opens with it.
    ///
    /// Matched as a PREFIX, not anywhere in the text. "as an AI" and "language
    /// model" appear legitimately in the middle of real output — the shipped
    /// Prompt Engineer Transform exists to write prompts for AI models, and its
    /// Role & stance section says things like "You are an AI assistant". A
    /// substring match rejected that built-in on its own core use case.
    static func isRefusal(_ text: String) -> Bool {
        let opening = text.prefix(60).lowercased()
        return refusalOpeners.contains { opening.hasPrefix($0) }
    }

    private static let refusalOpeners = [
        "as an ai", "i'm sorry", "i am sorry", "i cannot", "i can't", "i can not",
        "i'm unable", "i am unable", "sorry, ",
    ]

    /// The ceiling on how much longer the output may be than what was said.
    ///
    /// A ratio alone is wrong for templated Transforms. Prompt Engineer emits
    /// five fixed section headings — well over a hundred characters of
    /// scaffolding — before any content, so its SHORTEST and most natural uses
    /// blew the ratio while long rambling ones passed. The absolute floor is
    /// the room that scaffolding needs; the ratio still catches the degenerate
    /// repeat-until-token-limit failure on real input.
    static func expansionCeiling(forTranscript transcript: String) -> Double {
        max(Double(transcript.count) * maxExpansionRatio, absoluteFloor)
    }

    /// Generous enough for a structured prompt template plus its content.
    public static let absoluteFloor: Double = 1_200

    /// A phrase that appears in our own preamble and essentially never in real
    /// transformed prose. Its presence means the model echoed its brief.
    private static let instructionTell = "Output ONLY the transformed text"
}

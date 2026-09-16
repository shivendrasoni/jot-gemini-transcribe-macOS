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
        if stripped.range(of: "as an ai", options: .caseInsensitive) != nil
            || stripped.range(of: "language model", options: .caseInsensitive) != nil {
            return .fail("ai_selfreference", stripped)
        }
        if stripped.range(of: instructionTell, options: .caseInsensitive) != nil {
            return .fail("instruction_echo", stripped)
        }
        if transcript.count >= minTranscriptForRatio,
           Double(stripped.count) > Double(transcript.count) * maxExpansionRatio {
            return .fail("runaway_length", stripped)
        }
        return .ok(stripped)
    }

    /// A phrase that appears in our own preamble and essentially never in real
    /// transformed prose. Its presence means the model echoed its brief.
    private static let instructionTell = "Output ONLY the transformed text"
}

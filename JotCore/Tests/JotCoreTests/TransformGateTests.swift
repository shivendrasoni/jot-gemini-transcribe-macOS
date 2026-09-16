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

/// `ValidationGate` measures how far the cleaned text drifted from the raw
/// transcript, because drift is how an answering model gives itself away. A
/// Transform's whole job IS drift, so this gate cannot use that measure. What
/// is left is the small set of failures that are never legitimate: nothing came
/// back, the model talked about itself, it ran away, or it read the
/// instructions out loud.
final class TransformGateTests: XCTestCase {
    func testAcceptsAHeavyRewriteTheStrictGateWouldReject() {
        let transcript = "so um we should probably ship the thing on friday i think"
        let output = "**Title**\nShip Date\n\n**Task**\nConfirm the Friday release."

        XCTAssertTrue(TransformGate.validate(output: output, transcript: transcript).accepted)
        XCTAssertFalse(
            ValidationGate.validate(raw: transcript, cleaned: output).accepted,
            "if the strict gate ever starts accepting this, the two gates have converged and one is redundant"
        )
    }

    func testRejectsEmptyOutput() {
        let verdict = TransformGate.validate(output: "   \n ", transcript: "hello there")
        XCTAssertFalse(verdict.accepted)
        XCTAssertEqual(verdict.reason, "empty_output")
    }

    func testRejectsSelfReference() {
        let verdict = TransformGate.validate(
            output: "As an AI language model, I cannot help with that.",
            transcript: "hello there friend"
        )
        XCTAssertFalse(verdict.accepted)
        XCTAssertEqual(verdict.reason, "ai_selfreference")
    }

    func testRejectsRunawayExpansion() {
        let verdict = TransformGate.validate(
            output: String(repeating: "word ", count: 500),
            transcript: "ship it on friday please"
        )
        XCTAssertFalse(verdict.accepted)
        XCTAssertEqual(verdict.reason, "runaway_length")
    }

    /// Prompt Engineer legitimately turns one sentence into a structured block.
    /// The ceiling has to clear that or the built-in fails on its own use case.
    func testAcceptsAFourfoldExpansion() {
        let transcript = "help me write product descriptions for a skincare brand"
        let output = String(repeating: "structured prompt section ", count: 12)
        XCTAssertLessThan(transcript.count * 4, output.count, "must actually be a fourfold expansion")
        XCTAssertGreaterThan(transcript.count * 8, output.count, "but still under the ceiling")
        XCTAssertTrue(TransformGate.validate(output: output, transcript: transcript).accepted)
    }

    /// A two-word dictation legitimately expands far more than 8x, so the ratio
    /// must not apply to inputs too short to have a meaningful ratio.
    func testShortTranscriptsAreExemptFromTheRatio() {
        let verdict = TransformGate.validate(
            output: String(repeating: "expanded ", count: 40),
            transcript: "fix it"
        )
        XCTAssertTrue(verdict.accepted)
    }

    func testRejectsEchoOfTheInstruction() {
        let verdict = TransformGate.validate(
            output: "Output ONLY the transformed text. No preamble, no quotes, no commentary.",
            transcript: "hello there friend, how are you"
        )
        XCTAssertFalse(verdict.accepted)
        XCTAssertEqual(verdict.reason, "instruction_echo")
    }

    func testStripsArtifactsBeforeJudging() {
        let verdict = TransformGate.validate(output: "```\nClean text.\n```", transcript: "clean text")
        XCTAssertTrue(verdict.accepted)
    }

    /// The caller inserts `stripped`, not the raw response — a code-fenced
    /// answer must not reach the cursor wearing its fences.
    func testReturnsTheStrippedTextForInsertion()

    {
        let verdict = TransformGate.validate(output: "```\nClean text.\n```", transcript: "clean text")
        XCTAssertEqual(verdict.stripped, "Clean text.")
    }

    func testAcceptsOutputShorterThanTheTranscript() {
        let verdict = TransformGate.validate(
            output: "Ship Friday.",
            transcript: "so um i was thinking maybe we could possibly ship this on friday if that works"
        )
        XCTAssertTrue(verdict.accepted, "Simplify exists to make text shorter")
    }
}

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

/// A chord that arms a Transform: Option plus one key.
///
/// Stored as a KEYCODE, not a character. The event tap sees keycodes, and the
/// character a keycode produces changes with the keyboard layout — ⌥1 on a
/// French AZERTY is a different character entirely. The label is for display
/// only and is never what the tap matches on.
public struct TransformShortcut: Codable, Equatable, Hashable, Sendable {
    public let keyCode: Int64
    public let label: String

    public init(keyCode: Int64, label: String) {
        self.keyCode = keyCode
        self.label = label
    }

    /// Digits first, then letters. Digits come first because they are the ones
    /// people memorise, and the built-ins claim 1, 2, 3.
    public static let slots: [TransformShortcut] = digitSlots + letterSlots

    /// US-layout virtual keycodes for 1…9. (0 is deliberately absent: ⌥0 reads
    /// as "the tenth" and nobody counts that way under time pressure.)
    private static let digitSlots: [TransformShortcut] = zip(
        [18, 19, 20, 21, 23, 22, 26, 28, 25] as [Int64],
        ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
    ).map(TransformShortcut.init(keyCode:label:))

    private static let letterSlots: [TransformShortcut] = zip(
        [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
         45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6] as [Int64],
        "abcdefghijklmnopqrstuvwxyz".map(String.init)
    ).map(TransformShortcut.init(keyCode:label:))

    private static let byKeyCode: [Int64: TransformShortcut] = Dictionary(
        uniqueKeysWithValues: slots.map { ($0.keyCode, $0) }
    )

    public static func slot(forKeyCode keyCode: Int64) -> TransformShortcut? {
        byKeyCode[keyCode]
    }
}

/// A saved prompt the user can arm mid-dictation. The transcript is run through
/// it before anything is inserted, so nothing ever has to be rewritten in place.
public struct Transform: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Shown on the card and in the pill while armed. 1…40 chars.
    public var name: String
    /// Card subtitle. ≤80 chars.
    public var summary: String
    /// The instruction sent to the model. ≤4000 chars.
    public var prompt: String
    public var shortcut: TransformShortcut?
    /// True for the three Jot ships. Editing one keeps the flag — the flag says
    /// where it came from, and `resetToDefaults` is what undoes an edit.
    public var isBuiltIn: Bool
    public var order: Int
    public var createdAt: Date

    public static let maxNameLength = 40
    public static let maxSummaryLength = 80
    public static let maxPromptLength = 4_000

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        prompt: String,
        shortcut: TransformShortcut? = nil,
        isBuiltIn: Bool = false,
        order: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.prompt = prompt
        self.shortcut = shortcut
        self.isBuiltIn = isBuiltIn
        self.order = order
        self.createdAt = createdAt
    }

    /// Trimmed and length-capped. Applied on save so a pasted wall of text
    /// cannot become an unbounded request body.
    public var normalized: Transform {
        var copy = self
        copy.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        copy.summary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxSummaryLength))
        copy.prompt = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxPromptLength))
        return copy
    }

    /// A Transform with no prompt is a card that does nothing when pressed.
    public var isUsable: Bool {
        !normalized.name.isEmpty && !normalized.prompt.isEmpty
    }
}

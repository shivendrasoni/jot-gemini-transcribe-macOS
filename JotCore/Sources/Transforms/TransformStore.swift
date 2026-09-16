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

/// The saved Transforms. UserDefaults-backed JSON, the same shape as
/// `DictionaryStore` — entries are small and this keeps v1 dependency-free.
public struct TransformStore: Sendable {
    private static let key = "transforms"
    /// Above this the wheel stops being scannable and the grid stops being a
    /// grid. A ceiling also bounds what a corrupt import can do.
    public static let maxTransforms = 20

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reading

    /// The saved list, or the built-ins when nothing has been saved yet.
    ///
    /// The absent key IS the default state, which is what makes
    /// `resetToDefaults()` a deletion rather than a second copy of the seed
    /// list. Two copies would drift.
    public func transforms() -> [Transform] {
        guard let data = defaults.data(forKey: Self.key) else { return Self.builtIns }
        guard let decoded = try? JSONDecoder().decode([Transform].self, from: data) else {
            // A corrupt blob must not take the feature down with it. The user
            // gets the defaults rather than an empty grid and no explanation.
            Log.session.error("transforms store unreadable — falling back to defaults")
            return Self.builtIns
        }
        return decoded
    }

    public func transform(id: UUID) -> Transform? {
        transforms().first { $0.id == id }
    }

    public func transform(forShortcut shortcut: TransformShortcut) -> Transform? {
        transforms().first { $0.shortcut == shortcut }
    }

    // MARK: - Writing

    /// Normalizes, then writes. Both normalizations exist so no caller can
    /// bypass them: the cap bounds the list, and the uniqueness pass guarantees
    /// one chord resolves to exactly one Transform.
    public func save(_ transforms: [Transform]) {
        let normalized = Self.releasingDuplicateShortcuts(
            Array(transforms.prefix(Self.maxTransforms)).map(\.normalized)
        )
        guard let data = try? JSONEncoder().encode(normalized) else {
            Log.session.error("transforms could not be encoded — keeping the previous list")
            return
        }
        defaults.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: Self.key)
    }

    /// Replaces a Transform in place, or appends it if it is new. In place
    /// matters: editing a card must not make it jump to the end of the grid.
    public func upsert(_ transform: Transform) {
        var current = transforms()
        if let index = current.firstIndex(where: { $0.id == transform.id }) {
            current[index] = transform
        } else {
            current.append(transform)
        }
        save(current)
    }

    public func remove(id: UUID) {
        save(transforms().filter { $0.id != id })
    }

    /// Deletes the key, which is exactly what "no saved list" means.
    public func resetToDefaults() {
        defaults.removeObject(forKey: Self.key)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: Self.key)
    }

    // MARK: - Shortcut uniqueness

    /// Walks the list and lets the LAST claim on a chord win, clearing earlier
    /// ones. Last-write-wins is the rule a user can predict: the shortcut you
    /// just typed into the editor is the one you get.
    static func releasingDuplicateShortcuts(_ transforms: [Transform]) -> [Transform] {
        var seen = Set<TransformShortcut>()
        var result = transforms
        for index in result.indices.reversed() {
            guard let shortcut = result[index].shortcut else { continue }
            if seen.contains(shortcut) {
                result[index].shortcut = nil
            } else {
                seen.insert(shortcut)
            }
        }
        return result
    }

    // MARK: - Defaults

    /// The three Jot ships. Deliberately few: a first-run grid of twenty cards
    /// is a chore to read, and "Create your own" is the point of the feature.
    public static let builtIns: [Transform] = [
        Transform(
            name: "Polish",
            summary: "Improve clarity and conciseness",
            prompt: """
            Rewrite the dictated text as clean, polished prose.
            - Tighten wordy phrasing and remove repetition.
            - Keep every point the speaker made. Do not add points they did not make.
            - Keep their voice: contractions, directness, and level of formality stay as dictated.
            - Fix grammar and punctuation. Break long runs into sentences.
            """,
            shortcut: TransformShortcut.slots[0],
            isBuiltIn: true,
            order: 0
        ),
        Transform(
            name: "Prompt Engineer",
            summary: "Constructs optimal prompts",
            prompt: """
            Turn the dictated thought into a clean, structured prompt for an AI model.
            Use exactly these sections, in this order, omitting any the text gives you nothing for:

            **Title**
            (one concise line)

            **Role & stance**
            (who the model is and how it should behave)

            **Task**
            (what the model must do)

            **Context**
            (only what the model needs to know)

            **Output requirements**
            (format, structure, tone, length — only if specified; otherwise leave placeholders)

            Invent no requirements the speaker did not state.
            """,
            shortcut: TransformShortcut.slots[1],
            isBuiltIn: true,
            order: 1
        ),
        Transform(
            name: "Simplify",
            summary: "Plainer words, shorter sentences",
            prompt: """
            Rewrite the dictated text so a smart reader in a hurry gets it on the first pass.
            - Short sentences. One idea each.
            - Plain words over jargon, unless the jargon is the subject.
            - Cut every word that carries no information.
            - Keep all the facts and the first-person voice. Do not summarize away content.
            """,
            shortcut: TransformShortcut.slots[2],
            isBuiltIn: true,
            order: 2
        ),
    ]
}

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
import SwiftUI
import JotCore

/// The Transforms manager: a grid of saved prompts, each bound to an Option
/// chord you can press mid-sentence.
struct TransformsView: View {
    private let store = TransformStore()

    @State private var transforms: [Transform] = []
    @State private var editing: Transform?
    @State private var confirmingReset = false
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: JotUI.Spacing.s)]

    var body: some View {
        VStack(spacing: 0) {
            if let editing {
                TransformEditor(
                    transform: editing,
                    others: transforms.filter { $0.id != editing.id },
                    onSave: { save($0) },
                    onDelete: { delete(editing) },
                    onClose: { self.editing = nil }
                )
                // The editor seeds @State from its parameter, which SwiftUI
                // does NOT re-run when it reuses a view. Keying on the id
                // guarantees a fresh editor per Transform rather than one
                // showing the last one's text.
                .id(editing.id)
            } else {
                grid
                footer
            }
        }
        .onAppear(perform: reload)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: JotUI.Spacing.s) {
                ForEach(transforms) { transform in
                    card(for: transform)
                }
                createCard
            }
            .padding(JotUI.Spacing.m)
        }
    }

    private func card(for transform: Transform) -> some View {
        Button {
            editing = transform
        } label: {
            VStack(alignment: .leading, spacing: JotUI.Spacing.xs) {
                shortcutChip(transform.shortcut)
                Text(transform.name)
                    .font(JotUI.TypeScale.title(grad: grad))
                    .foregroundStyle(JotUI.Colors.onSurface)
                Text(transform.summary.isEmpty ? transform.prompt : transform.summary)
                    .font(JotUI.TypeScale.body(grad: grad))
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .padding(JotUI.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: JotUI.Radius.medium)
                    .fill(JotUI.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: JotUI.Radius.medium)
                            .stroke(JotUI.Colors.outlineVariant, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shortcutChip(_ shortcut: TransformShortcut?) -> some View {
        if let shortcut {
            HStack(spacing: 2) {
                chipKey("⌥ Opt")
                chipKey(shortcut.label)
            }
        } else {
            Text("No shortcut")
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                .frame(height: 22)
        }
    }

    private func chipKey(_ text: String) -> some View {
        Text(text)
            .font(JotUI.TypeScale.labelSmall(grad: grad))
            .foregroundStyle(JotUI.Colors.onSurface)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: JotUI.Radius.xs)
                    .fill(JotUI.Colors.surfaceContainer)
            )
    }

    private var createCard: some View {
        Button {
            editing = Transform(
                name: "", summary: "", prompt: "",
                shortcut: firstFreeShortcut(), order: transforms.count
            )
        } label: {
            VStack(alignment: .leading, spacing: JotUI.Spacing.xs) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(JotUI.Colors.surfaceContainer))
                Text("Create your own")
                    .font(JotUI.TypeScale.title(grad: grad))
                    .foregroundStyle(JotUI.Colors.onSurface)
                Text("Write a prompt, bind a shortcut")
                    .font(JotUI.TypeScale.body(grad: grad))
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .padding(JotUI.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: JotUI.Radius.medium)
                    .stroke(JotUI.Colors.outlineVariant, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .disabled(transforms.count >= TransformStore.maxTransforms)
    }

    private var footer: some View {
        HStack {
            Text(countLabel)
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            Spacer()
            Button("Reset to defaults") { confirmingReset = true }
                .font(JotUI.TypeScale.labelSmall(grad: grad))
        }
        .buttonStyle(.link)
        .padding(JotUI.Spacing.m)
        .confirmationDialog(
            "Reset Transforms to the three Jot ships?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                store.resetToDefaults()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your own Transforms and any edits to the built-in ones will be deleted.")
        }
    }

    private var countLabel: String {
        "Hold your dictation key, then tap ⌥ and the number · \(transforms.count) \(transforms.count == 1 ? "Transform" : "Transforms")"
    }

    // MARK: - Actions

    private func reload() {
        transforms = store.transforms()
    }

    private func save(_ transform: Transform) {
        store.upsert(transform.normalized)
        editing = nil
        reload()
    }

    private func delete(_ transform: Transform) {
        store.remove(id: transform.id)
        editing = nil
        reload()
    }

    /// Offers a chord that is actually free, so a new Transform does not
    /// silently steal one from an existing card the moment it is saved.
    private func firstFreeShortcut() -> TransformShortcut? {
        let taken = Set(transforms.compactMap(\.shortcut))
        return TransformShortcut.slots.first { !taken.contains($0) }
    }
}

/// Name, summary, shortcut and prompt for one Transform.
private struct TransformEditor: View {
    @State var transform: Transform
    /// Every other saved Transform — needed to warn that a chord is about to be
    /// taken off one of them.
    let others: [Transform]
    let onSave: (Transform) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var trying = false
    @State private var sampleResult: String?

    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    private var isNew: Bool { transform.name.isEmpty && transform.prompt.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: JotUI.Spacing.m) {
                    field("Name") {
                        TextField("Polish", text: $transform.name)
                            .textFieldStyle(.plain)
                            .font(JotUI.TypeScale.bodyLarge(grad: grad))
                    }
                    field("Description") {
                        TextField("Improve clarity and conciseness", text: $transform.summary)
                            .textFieldStyle(.plain)
                            .font(JotUI.TypeScale.body(grad: grad))
                    }
                    field("Keyboard shortcut") {
                        VStack(alignment: .leading, spacing: JotUI.Spacing.xxs) {
                            Picker("", selection: shortcutBinding) {
                                Text("None").tag(TransformShortcut?.none)
                                ForEach(TransformShortcut.slots, id: \.keyCode) { slot in
                                    Text("⌥ \(slot.label)").tag(TransformShortcut?.some(slot))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            // One chord resolves to exactly one Transform, so
                            // saving this takes it off the other one. Say so
                            // before the save, not after it silently happens.
                            if let holder = currentHolder {
                                Text("Saving this takes ⌥\(transform.shortcut?.label ?? "") off \(holder.name).")
                                    .font(JotUI.TypeScale.labelSmall(grad: grad))
                                    .foregroundStyle(JotUI.Colors.error)
                            }
                        }
                    }
                    field("Prompt") {
                        TextEditor(text: $transform.prompt)
                            .font(JotUI.TypeScale.body(grad: grad))
                            .frame(minHeight: 220)
                            .scrollContentBackground(.hidden)
                    }
                    Text("Your dictation is added below this prompt, fenced, and labelled as speech — so a dictation that contains an instruction gets transformed, never obeyed.")
                        .font(JotUI.TypeScale.labelSmall(grad: grad))
                        .foregroundStyle(JotUI.Colors.onSurfaceVariant)

                    tryItSection
                }
                .padding(JotUI.Spacing.m)
            }
        }
    }

    /// Answers "what will this actually do" on demand.
    ///
    /// A button rather than a live preview: a preview that re-renders as you
    /// type would bill the user for an API call per keystroke, for an answer
    /// they only want once.
    private var tryItSection: some View {
        VStack(alignment: .leading, spacing: JotUI.Spacing.xs) {
            HStack(spacing: JotUI.Spacing.s) {
                Button(trying ? "Running…" : "Try it") { runSample() }
                    .font(JotUI.TypeScale.labelSmall(grad: grad))
                    .disabled(trying || !transform.isUsable)
                Text("on “\(Self.sample)”")
                    .font(JotUI.TypeScale.labelSmall(grad: grad))
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    .lineLimit(1)
            }
            if let sampleResult {
                Text(sampleResult)
                    .font(JotUI.TypeScale.body(grad: grad))
                    .foregroundStyle(JotUI.Colors.onSurface)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(JotUI.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: JotUI.Radius.small)
                            .fill(JotUI.Colors.surfaceContainer)
                    )
            }
        }
    }

    /// Deliberately messy: fillers, a self-correction, no punctuation — so the
    /// sample shows what the prompt does with real dictation rather than with
    /// text that is already clean.
    private static let sample =
        "so um i was thinking we should probably ship the thing on thursday actually no friday"

    private func runSample() {
        trying = true
        sampleResult = nil
        let prompt = TransformPromptV1.prompt(transform: transform.normalized, transcript: Self.sample)
        Task { @MainActor in
            defer { trying = false }
            guard KeychainStore.loadAPIKey() != nil else {
                sampleResult = "Add your Gemini API key in Settings → Advanced first."
                return
            }
            let client = GeminiClient(apiKey: { KeychainStore.loadAPIKey() })
            do {
                let output = try await client.transform(
                    prompt: prompt, deadline: TransformingTranscriptionService.transformDeadline
                )
                // Judged by the same gate the real path uses, so the preview
                // cannot show something a dictation would have rejected.
                let verdict = TransformGate.validate(output: output, transcript: Self.sample)
                sampleResult = verdict.accepted
                    ? verdict.stripped
                    : "That came back unusable (\(verdict.reason ?? "rejected")) — a dictation would have been inserted as spoken."
            } catch {
                Log.ui.info("transform preview failed: \(String(describing: error), privacy: .public)")
                sampleResult = "Couldn't reach the model just now."
            }
        }
    }

    /// `Picker` needs a two-way binding over an Optional tag; the shortcut is
    /// stored on the struct, so this bridges the two.
    private var shortcutBinding: Binding<TransformShortcut?> {
        Binding(get: { transform.shortcut }, set: { transform.shortcut = $0 })
    }

    /// The Transform that currently holds the chord being picked, if it is not
    /// this one.
    private var currentHolder: Transform? {
        guard let shortcut = transform.shortcut else { return nil }
        return others.first { $0.shortcut == shortcut }
    }

    private var header: some View {
        HStack(spacing: JotUI.Spacing.s) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            }
            .buttonStyle(.plain)

            Text(isNew ? "New Transform" : transform.name)
                .font(JotUI.TypeScale.title(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurface)

            Spacer()

            if !isNew {
                Button("Delete", role: .destructive, action: onDelete)
                    .font(JotUI.TypeScale.labelSmall(grad: grad))
                    .buttonStyle(.link)
            }
            Button("Save") { onSave(transform) }
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .disabled(!transform.isUsable)
                .help(transform.isUsable ? "" : "A Transform needs a name and a prompt")
        }
        .padding(JotUI.Spacing.m)
        .background(JotUI.Colors.surfaceContainer)
    }

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: JotUI.Spacing.xxs) {
            Text(label)
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            content()
                .padding(JotUI.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: JotUI.Radius.small)
                        .fill(JotUI.Colors.surfaceContainer)
                )
        }
    }
}

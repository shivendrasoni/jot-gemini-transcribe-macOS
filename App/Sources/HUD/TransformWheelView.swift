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

import SwiftUI
import JotCore

/// The Transform wheel: what you see when you hold ⌥ mid-dictation.
///
/// Drawn as a horizontal arc of cards rather than a pie. With up to twenty
/// Transforms a true radial is twenty unreadable slices, and the arc keeps both
/// the scrolling-wheel feel and the card language of the Transforms settings
/// pane. If a real radial is ever wanted it is a view swap, not a change to
/// anything behind it.
///
/// Purely presentational: selection lives in `HotkeyProcessor`, which is where
/// it can be reasoned about and tested without a screen.
struct TransformWheelView: View {
    let wheel: TransformWheelModel

    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    /// Cards fall away either side of the highlight, so the eye lands on the
    /// choice rather than scanning a flat row.
    private static let arcLift: CGFloat = 10

    var body: some View {
        VStack(spacing: JotUI.Spacing.xs) {
            HStack(spacing: JotUI.Spacing.xs) {
                ForEach(Array(wheel.entries.enumerated()), id: \.element.id) { index, entry in
                    card(
                        entry,
                        isHighlighted: index == wheel.highlighted,
                        distance: wheel.highlighted.map { abs(index - $0) } ?? 0
                    )
                }
            }
            Text(wheel.highlighted == nil
                 ? "← → or a number to choose · esc to close"
                 : "release ⌥ to apply · esc to close")
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
        }
        .padding(JotUI.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: JotUI.Radius.large)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: JotUI.Radius.large)
                        .stroke(JotUI.Colors.outlineVariant.opacity(0.6), lineWidth: 1)
                )
        )
        .animation(JotMotion.defaultSpatial, value: wheel.highlighted)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private func card(_ entry: TransformWheelModel.Entry, isHighlighted: Bool, distance: Int) -> some View {
        VStack(spacing: 4) {
            Text(entry.shortcut.map { "⌥\($0)" } ?? "—")
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(isHighlighted ? JotUI.Colors.onPrimaryContainer : JotUI.Colors.onSurfaceVariant)
            Text(entry.name)
                .font(JotUI.TypeScale.label(grad: grad))
                .foregroundStyle(isHighlighted ? JotUI.Colors.onPrimaryContainer : JotUI.Colors.onSurface)
                .lineLimit(1)
        }
        .padding(.horizontal, JotUI.Spacing.s)
        .padding(.vertical, JotUI.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: JotUI.Radius.medium)
                .fill(isHighlighted ? JotUI.Colors.primaryContainer : JotUI.Colors.surfaceContainer)
        )
        .scaleEffect(isHighlighted ? 1.0 : 0.9)
        .opacity(isHighlighted ? 1.0 : 0.75)
        .offset(y: Self.arcLift * min(CGFloat(distance), 3) / 3)
    }
}

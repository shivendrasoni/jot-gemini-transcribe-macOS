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

/// Owns the non-activating NSPanel that hosts the pill. Fixed-size panel; the pill
/// animates its own bounds inside (avoids NSWindow frame-animation jank).
/// The panel never becomes key except transiently for the locked-state stop button.
@MainActor
final class PillHUDController {
    let model = PillModel()
    private let panel: NSPanel

    init() {
        // Tall enough for the Transform wheel to sit above the pill.
        //
        // A fixed tall panel rather than one that resizes when the wheel opens:
        // NSWindow frame animation is exactly the jank this class already
        // avoids for the pill, and the extra height is invisible — the panel is
        // transparent and its content is bottom-anchored. SwiftUI does not
        // hit-test empty space, so the larger panel intercepts nothing.
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 220),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(
            rootView: PillRootView(model: model)
        )
        reposition()
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    /// Called at each session start so the pill follows the display the user is
    /// actually dictating on (audit L14 — it used to stick to the launch screen).
    func repositionToActiveScreen() {
        reposition()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Bottom-center of the screen hosting the FOCUSED window — where the text
    /// will actually land. Mouse position is only a fallback: keyboard-first
    /// users routinely dictate on one display with the pointer parked on
    /// another (production pass 2). Doesn't jump mid-session (spec §1.1).
    private func reposition() {
        let screen = Self.screenOfFocusedWindow()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 16
        ))
    }

    /// Screen hosting the frontmost app's front window, via the window list —
    /// a local syscall, never an AX round-trip into the target app. The AX
    /// version could block ~100ms per attribute on a busy app, and this runs
    /// on the key-press path where the pill must appear instantly (dogfood).
    private static func screenOfFocusedWindow() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // The list is front-to-back; the first normal-layer window owned by the
        // frontmost app is its focused/front window.
        guard let info = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        }), let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        let midX = (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2
        let midY = (bounds["Y"] ?? 0) + (bounds["Height"] ?? 0) / 2
        // Window-list coords are top-left-origin global; flip into Cocoa space.
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaPoint = NSPoint(x: midX, y: primary.frame.maxY - midY)
        return NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) })
    }
}

private struct PillRootView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        VStack(spacing: JotUI.Spacing.xs) {
            Spacer(minLength: 0)
            if let wheel = model.wheel {
                TransformWheelView(wheel: wheel)
            }
            PillView(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
        // The pill stays put; only the wheel animates in above it.
        .animation(JotMotion.defaultSpatial, value: model.wheel == nil)
    }
}

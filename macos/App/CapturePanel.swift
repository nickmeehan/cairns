import AppKit
import SwiftUI

/// One reused floating panel hosting the SwiftUI capture editor —
/// Spotlight-for-notes: instant, unadorned, gone when done. Reused (never
/// re-created) so the hotkey just shows + focuses the single instance.
@MainActor
final class CapturePanelController {
    private var panel: NSPanel?
    private var root = AnyView(EmptyView())

    func setRootView(_ view: some View) {
        root = AnyView(view)
    }

    func show() {
        let window = panel ?? makePanel()
        panel = window
        // ponytail: activate + fullScreenAuxiliary reliably focuses the editor
        // over any space; switch to .nonactivatingPanel if focus-stealing is
        // ever a complaint (loses guaranteed text focus, so not the default).
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let window = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = NSHostingView(rootView: root)
        return window
    }
}

/// NSPanel that can hold text focus and hides (not closes) on Esc.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_: Any?) {
        orderOut(nil)
    }
}

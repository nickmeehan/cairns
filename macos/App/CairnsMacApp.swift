import AppKit
import SwiftUI

// ponytail: no GitHub sign-in on the Mac — pushes go through GitSync using the
// user's own git credentials (ssh key / helper), so the app never holds a token.
@main
struct CairnsApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        MenuBarExtra("Cairns", systemImage: "mountain.2.fill") {
            MenuContent(app: app, sync: app.sync)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}

/// The menu-bar dropdown. Two states: not-yet-configured (one "Set Up" item)
/// and configured (capture + sync controls). The status line reflects
/// SyncController's last outcome.
struct MenuContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject var sync: SyncController

    var body: some View {
        if app.isConfigured {
            Button("New Capture") { app.showCapture() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Text(sync.statusText)
            Button("Push Now") { Task { await sync.pushNow() } }
            Button("Pull Now") { Task { await sync.pullNow() } }
        } else {
            Button("Set Up Cairns…") { app.openSettings() }
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Cairns") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

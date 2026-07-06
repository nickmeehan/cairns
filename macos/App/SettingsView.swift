import AppKit
import SwiftUI

/// Clone path (validated), capture subfolder, and pull cadence. Everything
/// persists through AppModel's @Published properties (UserDefaults-backed).
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            Section("Notes repository") {
                repoRow
                if let error = app.cloneError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
                TextField("Subfolder (empty = repo root)", text: $app.subfolder)
            }
            Section("Sync") {
                Picker("Pull every", selection: $app.pullMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private var repoRow: some View {
        HStack {
            Text(app.clonePath.isEmpty ? "No folder chosen" : app.clonePath)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(app.clonePath.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer()
            Button("Choose…") { chooseClone() }
        }
    }

    private func chooseClone() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url {
            app.clonePath = url.path
        }
    }
}

import CairnsKit
import SwiftUI

/// The screen. Launch lands here focused on a blank editor so dictation is one
/// tap away. Saves hand off to the durable queue; the editor clears instantly.
struct CaptureView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var flash: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal)
                .scrollContentBackground(.hidden)
                .onChange(of: text) { _, value in model.scheduleDraftSave(value) }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .overlay(alignment: .top) { flashView }
        }
        .task { await start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.drainQueue() } }
        }
        .onChange(of: model.conflictNotice) { _, notice in
            guard let notice else { return }
            showFlash("Saved as \(notice)")
            model.clearConflictNotice()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink { NotesListView(model: model) } label: {
                Image(systemName: "list.bullet")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink { SettingsView(model: model) } label: {
                Image(systemName: "gearshape")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 8) {
                syncIndicator
                Button("Save", action: save).disabled(text.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var syncIndicator: some View {
        if model.isDraining {
            Text("Saving…").font(.footnote).foregroundStyle(.secondary)
        } else if model.unsyncedCount > 0 {
            Text("\(model.unsyncedCount) unsynced")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var flashView: some View {
        if let flash {
            Text(flash)
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    private func start() async {
        text = model.loadDraft()
        focused = true
        await model.drainQueue()
    }

    private func save() {
        let pending = text
        text = "" // durability already transferred to the queue on enqueue
        focused = true
        Task {
            let result = await model.saveCapture(text: pending)
            showFlash(result == .saved ? "Saved" : "Saved offline")
        }
    }

    private func showFlash(_ message: String) {
        flash = message
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if flash == message { flash = nil }
        }
    }
}

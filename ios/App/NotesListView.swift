import CairnsKit
import SwiftUI

/// Notes already in the repo folder, newest first. Capture filenames sort
/// chronologically, so a reverse name sort is newest-first.
struct NotesListView: View {
    let model: AppModel
    @State private var files: [RepoFile] = []
    @State private var loaded = false

    var body: some View {
        List(files, id: \.path) { file in
            NavigationLink {
                EditNoteView(model: model, file: file)
            } label: {
                Text(Filenames.describeCaptureFilename(file.name) ?? file.name)
            }
        }
        .overlay { emptyState }
        .navigationTitle("Notes")
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if loaded, files.isEmpty {
            ContentUnavailableView("No notes yet", systemImage: "note.text")
        }
    }

    private func load() async {
        guard let api = model.api, let repo = model.repo else { return }
        let all = await (try? api.listFolder(repo, path: model.subfolder)) ?? []
        files = all
            .filter { !$0.isDirectory && $0.name.hasSuffix(".md") }
            .sorted { $0.name > $1.name }
        loaded = true
    }
}

/// Edit an existing note: fetch content + SHA, then enqueue an update on save.
struct EditNoteView: View {
    let model: AppModel
    let file: RepoFile
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sha = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .padding(.horizontal)
            .scrollContentBackground(.hidden)
            .navigationTitle(Filenames.describeCaptureFilename(file.name) ?? file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).disabled(!loaded)
                }
            }
            .overlay { if !loaded { ProgressView() } }
            .task { await load() }
    }

    private func load() async {
        guard let api = model.api, let repo = model.repo else { return }
        guard let result = try? await api.fileContent(repo, path: file.path) else { return }
        text = result.content
        sha = result.sha
        loaded = true
    }

    private func save() {
        Task {
            _ = await model.saveUpdate(path: file.path, content: text,
                                       sha: sha, filename: file.name)
            dismiss()
        }
    }
}

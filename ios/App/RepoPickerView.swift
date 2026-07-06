import CairnsKit
import SwiftUI

/// Pick an owned repo, then a subfolder. Owns its own NavigationStack since it
/// is a top-level phase, not pushed onto another.
struct RepoPickerView: View {
    let model: AppModel
    @State private var repos: [RepoRef] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List(repos, id: \.self) { repo in
                NavigationLink(value: repo) {
                    Text("\(repo.owner)/\(repo.name)")
                }
            }
            .overlay { if !loaded { ProgressView() } }
            .navigationTitle("Choose a repo")
            .navigationDestination(for: RepoRef.self) { repo in
                SubfolderView(model: model, repo: repo)
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = model.api else { loaded = true; return }
        repos = await (try? api.repositories()) ?? []
        loaded = true
    }
}

/// Subfolder within the repo. Empty = repo root.
struct SubfolderView: View {
    let model: AppModel
    let repo: RepoRef
    @State private var subfolder = ""

    var body: some View {
        Form {
            Section {
                TextField("inbox", text: $subfolder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("Notes are saved here. Leave empty for the repo root.")
            }
            Button("Save notes to \(repo.name)") {
                model.selectRepo(repo, subfolder: subfolder)
            }
        }
        .navigationTitle("Subfolder")
        .navigationBarTitleDisplayMode(.inline)
    }
}

import CairnsKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Signed in as", value: model.login ?? "—")
            }
            Section("Repository") {
                if let repo = model.repo {
                    LabeledContent("Repo", value: "\(repo.owner)/\(repo.name)")
                }
                LabeledContent("Subfolder",
                               value: model.subfolder.isEmpty ? "(root)" : model.subfolder)
                Button("Change repo or subfolder") { model.changeRepo() }
            }
            Section {
                Button("Sign out", role: .destructive) { model.signOut() }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

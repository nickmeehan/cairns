import CairnsKit
import SwiftUI

@main
struct CairnsApp: App {
    @State private var model: AppModel

    init() {
        let support = URL.applicationSupportDirectory.appending(path: "Cairns")
        let drafts = support.appending(path: "drafts")
        let queueDir = support.appending(path: "queue")
        let manager = FileManager.default
        try? manager.createDirectory(at: drafts, withIntermediateDirectories: true)
        try? manager.createDirectory(at: queueDir, withIntermediateDirectories: true)
        _model = State(initialValue: AppModel(
            tokenStore: KeychainTokenStore(),
            queue: CaptureQueue(directory: queueDir),
            draftStore: DraftStore(directory: drafts),
            defaults: .standard
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

/// Phase switch is the whole navigation model — three linear phases, no router.
struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .signIn: SignInView(model: model)
            case .pickRepo: RepoPickerView(model: model)
            case .capture: CaptureView(model: model)
            }
        }
        .task { await model.onLaunch() }
    }
}

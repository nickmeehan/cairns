import AppKit
import CairnsKit
import SwiftUI

/// Top-level coordinator: owns settings, the global hotkey, the capture panel,
/// and the sync engine. All git/logic lives in CairnsKit — this only composes.
@MainActor
final class AppModel: ObservableObject {
    @Published var clonePath: String = "" {
        didSet {
            UserDefaults.standard.set(clonePath, forKey: "clonePath")
            configure()
        }
    }

    @Published var subfolder: String = "" {
        didSet {
            UserDefaults.standard.set(subfolder, forKey: "subfolder")
            configure()
        }
    }

    @Published var pullMinutes: Int = 5 {
        didSet {
            UserDefaults.standard.set(pullMinutes, forKey: "pullMinutes")
            sync.pullMinutes = pullMinutes
        }
    }

    @Published private(set) var isConfigured = false
    @Published var cloneError: String?

    let sync = SyncController()
    let capture = CaptureModel()
    private let panel = CapturePanelController()
    private var hotKey: HotKey?

    init() {
        clonePath = UserDefaults.standard.string(forKey: "clonePath") ?? ""
        subfolder = UserDefaults.standard.string(forKey: "subfolder") ?? ""
        pullMinutes = UserDefaults.standard.object(forKey: "pullMinutes") as? Int ?? 5
        wire()
        configure()
    }

    private func wire() {
        capture.requestHide = { [weak self] in self?.panel.hide() }
        capture.afterSave = { [weak self] in Task { await self?.sync.pushNow() } }
        panel.setRootView(CaptureView(model: capture))
        sync.pullMinutes = pullMinutes
        hotKey = HotKey { [weak self] in self?.showCapture() }
    }

    private func configure() {
        let path = clonePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            isConfigured = false
            cloneError = nil
            sync.use(nil)
            return
        }
        let url = URL(fileURLWithPath: path)
        guard GitSync.validateClone(at: url) else {
            isConfigured = false
            cloneError = "Not a git repository with a remote."
            sync.use(nil)
            return
        }
        isConfigured = true
        cloneError = nil
        sync.use(GitSync(clone: url, subfolder: subfolder))
    }

    func showCapture() {
        guard isConfigured, let git = sync.current else {
            openSettings()
            return
        }
        panel.show()
        Task { await capture.begin(sync: git) }
    }

    // ponytail: standard AppKit "showSettingsWindow:" action opens the Settings
    // scene from non-view code (hotkey / "Set Up"); the menu uses SettingsLink.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

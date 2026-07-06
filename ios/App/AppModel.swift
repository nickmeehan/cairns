import CairnsKit
import Foundation
import Observation

/// Persisted config (UserDefaults JSON): the chosen repo + subfolder, plus the
/// cached login used to scope the queue and stamp PendingWrite.enqueuedFor.
struct RepoSelection: Codable, Equatable {
    var repo: RepoRef
    var subfolder: String
}

struct Config: Codable {
    var login: String?
    var selection: RepoSelection?
}

enum Phase: Equatable {
    case signIn, pickRepo, capture
}

enum SaveConfirmation: Equatable {
    case saved, savedOffline
}

/// The one @Observable model. Holds auth/config state + the phase, and owns the
/// enqueue → drain orchestration. All logic proper lives in CairnsKit; this
/// just composes it. Boot is optimistic: never gate the editor on the network.
@MainActor
@Observable
final class AppModel {
    private(set) var phase: Phase
    private(set) var login: String?
    private(set) var unsyncedCount = 0
    private(set) var isDraining = false
    /// Filename a conflicted note landed at (409 → sibling copy) — the capture
    /// screen flashes it so the user knows where their words went.
    private(set) var conflictNotice: String?

    let queue: CaptureQueue
    private(set) var api: GitHubAPI?

    private let tokenStore: any TokenStore
    private let draftStore: DraftStore
    private let defaults: UserDefaults
    private var config: Config
    private var draftSaveTask: Task<Void, Never>?

    private static let configKey = "cairns.config"

    var repo: RepoRef? { config.selection?.repo }
    var subfolder: String { config.selection?.subfolder ?? "" }

    init(tokenStore: any TokenStore, queue: CaptureQueue,
         draftStore: DraftStore, defaults: UserDefaults)
    {
        self.tokenStore = tokenStore
        self.queue = queue
        self.draftStore = draftStore
        self.defaults = defaults
        let loaded = Self.loadConfig(from: defaults)
        config = loaded
        // Read the local, not self.config: @Observable forbids touching a
        // tracked property before every stored property is initialized.
        if let token = try? tokenStore.load(), let login = loaded.login {
            api = GitHubAPI(token: token)
            self.login = login
            phase = loaded.selection != nil ? .capture : .pickRepo
        } else {
            phase = .signIn
        }
    }

    // MARK: Launch

    /// Wires the sync-count observation, then optimistically verifies the token
    /// in the background (only in capture phase — the editor is already up).
    func onLaunch() async {
        await queue.setOnCountChange { [weak self] count in
            Task { @MainActor in self?.unsyncedCount = count }
        }
        await queue.setOnConflict { [weak self] _, siblingPath in
            let name = siblingPath.components(separatedBy: "/").last ?? siblingPath
            Task { @MainActor in self?.conflictNotice = name }
        }
        unsyncedCount = await queue.count()
        await verifyToken()
    }

    func clearConflictNotice() { conflictNotice = nil }

    private func verifyToken() async {
        guard case .capture = phase, let api, let expected = login else { return }
        do {
            let user = try await api.user()
            if user.login != expected { signOut() } // different account
        } catch GitHubAPIError.unauthorized {
            signOut()
        } catch {
            // ponytail: transient (network/5xx/403) — stay quiet, retry next launch.
        }
    }

    // MARK: Auth / config transitions

    func completeSignIn(token: String, login: String) async {
        try? tokenStore.save(token)
        config.login = login
        self.login = login
        api = GitHubAPI(token: token)
        saveConfig()
        try? await queue.prune(keepingRowsFor: login)
        unsyncedCount = await queue.count()
        phase = .pickRepo
    }

    func selectRepo(_ repo: RepoRef, subfolder: String) {
        let trimmed = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        config.selection = RepoSelection(repo: repo, subfolder: trimmed)
        saveConfig()
        phase = .capture
    }

    func changeRepo() { phase = .pickRepo }

    /// Sign out clears the Keychain token only — drafts and queue rows stay, per
    /// the notes-repo contract. Also the 401 / different-login route.
    func signOut() {
        try? tokenStore.clear()
        api = nil
        phase = .signIn
    }

    // MARK: Save + drain

    func saveCapture(text: String) async -> SaveConfirmation {
        guard let repo, let login else { return .savedOffline }
        let filename = Filenames.captureFilename()
        let path = joinPath(subfolder, filename)
        let write = PendingWrite(kind: .new, repo: repo, path: path, content: text,
                                 message: CommitMessages.add(filename), enqueuedFor: login)
        try? await queue.enqueue(write)
        try? draftStore.discard()
        return await drainForConfirmation()
    }

    func saveUpdate(path: String, content: String, sha: String,
                    filename: String) async -> SaveConfirmation
    {
        guard let repo, let login else { return .savedOffline }
        let write = PendingWrite(kind: .update, repo: repo, path: path, content: content,
                                 sha: sha, message: CommitMessages.update(filename),
                                 enqueuedFor: login)
        try? await queue.enqueue(write)
        return await drainForConfirmation()
    }

    private func drainForConfirmation() async -> SaveConfirmation {
        if case .drained = await drainQueue() { return .saved }
        return .savedOffline
    }

    @discardableResult
    func drainQueue() async -> DrainResult {
        guard let api else { return .halted(remaining: 0) }
        isDraining = true
        let result = await queue.drain(api: api)
        isDraining = false
        if case .unauthorized = result { signOut() } // rows preserved
        return result
    }

    // MARK: Draft durability

    func loadDraft() -> String {
        (try? draftStore.load()) ?? ""
    }

    /// Debounced ~300ms write, off-main so keystrokes never touch the file loop.
    func scheduleDraftSave(_ text: String) {
        draftSaveTask?.cancel()
        draftSaveTask = Task.detached { [draftStore] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            try? draftStore.save(text)
        }
    }

    // MARK: Helpers

    private func joinPath(_ folder: String, _ filename: String) -> String {
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? filename : "\(trimmed)/\(filename)"
    }

    private static func loadConfig(from defaults: UserDefaults) -> Config {
        guard let data = defaults.data(forKey: configKey),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    private func saveConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.configKey)
    }
}

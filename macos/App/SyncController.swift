import CairnsKit
import Foundation

/// The macOS sync engine wrapper. Pushes after every save, retries every 30s
/// while commits stay unpushed, and pulls on a cadence. GitSync (an actor) does
/// the git work and serialises it; this just schedules and reflects outcomes.
@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var unpushed = 0
    @Published private(set) var lastProblem: String?

    var pullMinutes = 5 {
        didSet { startPullLoop() }
    }

    private var sync: GitSync?
    private var retry: Task<Void, Never>?
    private var pullLoop: Task<Void, Never>?

    var current: GitSync? { sync }

    var statusText: String {
        if let lastProblem { return lastProblem }
        return unpushed > 0 ? "\(unpushed) unsynced" : "Synced"
    }

    func use(_ git: GitSync?) {
        retry?.cancel()
        retry = nil
        sync = git
        lastProblem = nil
        unpushed = 0
        guard git != nil else {
            pullLoop?.cancel()
            pullLoop = nil
            return
        }
        startPullLoop()
        Task { await pullNow() }
    }

    func pushNow() async {
        await push()
        scheduleRetry()
    }

    func pullNow() async {
        guard let sync else { return }
        await note(sync.pull())
        unpushed = await (try? sync.unpushedCount()) ?? unpushed
    }

    private func push() async {
        guard let sync else { return }
        await note(sync.tryPush())
        unpushed = await (try? sync.unpushedCount()) ?? unpushed
    }

    private func scheduleRetry() {
        if unpushed > 0, retry == nil {
            retry = Task { [weak self] in await self?.retryLoop() }
        } else if unpushed == 0 {
            retry?.cancel()
            retry = nil
        }
    }

    private func retryLoop() async {
        while unpushed > 0 {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await push()
        }
        retry = nil
    }

    private func startPullLoop() {
        pullLoop?.cancel()
        let seconds = Double(pullMinutes) * 60
        pullLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                await self?.pullNow()
            }
        }
    }

    private func note(_ outcome: PushOutcome) {
        if case let .gitError(message) = outcome {
            lastProblem = "Git error: \(message)"
            return
        }
        lastProblem = outcome.shortText
    }

    private func note(_ outcome: PullOutcome) {
        if case let .gitError(message) = outcome {
            lastProblem = "Git error: \(message)"
            return
        }
        lastProblem = outcome.shortText
    }
}

private extension PushOutcome {
    /// nil for the success cases (clears the status line).
    var shortText: String? {
        if self == .noUpstream { return "Push failed: no upstream" }
        if self == .networkError { return "Offline — will retry" }
        if self == .rebaseFailed { return "Rebase needed — resolve in terminal" }
        if self == .authFailed { return "Push failed: check git credentials" }
        return nil
    }
}

private extension PullOutcome {
    var shortText: String? {
        if self == .networkError { return "Offline — will retry" }
        if self == .rebaseFailed { return "Rebase needed — resolve in terminal" }
        return nil
    }
}

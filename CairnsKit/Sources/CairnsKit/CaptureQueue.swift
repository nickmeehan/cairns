import Foundation

/// One durable draft (the note being typed right now), stored as a file so a
/// crash mid-thought loses nothing. The iOS shell debounces writes (~300ms).
public struct DraftStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func save(_: String) throws { fatalError("unimplemented") }
    public func load() throws -> String? { fatalError("unimplemented") }
    public func discard() throws { fatalError("unimplemented") }
}

public struct PendingWrite: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case new, update
    }

    public var id: UUID
    public var kind: Kind
    public var repo: RepoRef
    public var path: String
    public var content: String
    /// Update rows only; refetched fresh at drain time anyway.
    public var sha: String?
    public var message: String
    /// GitHub login this row belongs to — another account's rows never push.
    public var enqueuedFor: String
    public var attempts: Int
    public var lastError: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, repo: RepoRef, path: String, content: String,
                sha: String? = nil, message: String, enqueuedFor: String,
                attempts: Int = 0, lastError: String? = nil, createdAt: Date = Date())
    {
        self.id = id
        self.kind = kind
        self.repo = repo
        self.path = path
        self.content = content
        self.sha = sha
        self.message = message
        self.enqueuedFor = enqueuedFor
        self.attempts = attempts
        self.lastError = lastError
        self.createdAt = createdAt
    }
}

public enum DrainResult: Sendable, Equatable {
    case drained // queue empty
    case halted(remaining: Int) // network/5xx/401 — wait for next trigger
    case unauthorized(remaining: Int) // 401 specifically — route to re-auth
}

/// The iOS save path: every save is enqueued first (durability), then the
/// queue drains FIFO — immediately when online, later when not. Mirrors
/// trailhead's sync-queue semantics:
///  - fresh SHA before every update commit
///  - 409 on update → commit to Filenames.conflictSiblingPath, row cleared
///  - 401 → halt whole queue, preserve rows, surface .unauthorized
///  - network/5xx → halt (retry on next trigger), other 4xx → drop the row
///  - `new` rows never dedupe; an `update` row replaces a queued update
///    for the same path (latest content wins)
/// Rows persist as JSON files under `directory` — survives relaunch.
public actor CaptureQueue {
    public let directory: URL

    /// Fires on every count change (enqueue/drain/prune) with the new count —
    /// the shells' sync indicator ("N unsynced") observes this.
    public var onCountChange: (@Sendable (Int) -> Void)?

    public init(directory: URL) {
        self.directory = directory
    }

    public func setOnCountChange(_ handler: (@Sendable (Int) -> Void)?) {
        onCountChange = handler
    }

    public func enqueue(_: PendingWrite) throws {
        fatalError("unimplemented")
    }

    public func count() -> Int {
        fatalError("unimplemented")
    }

    public func rows() -> [PendingWrite] {
        fatalError("unimplemented")
    }

    /// Drop rows not belonging to `login` — runs at boot before any drain.
    public func prune(keepingRowsFor _: String) throws {
        fatalError("unimplemented")
    }

    /// One drain runs at a time; concurrent calls share the in-flight run.
    public func drain(api _: any GitHubWriting) async -> DrainResult {
        fatalError("unimplemented")
    }
}

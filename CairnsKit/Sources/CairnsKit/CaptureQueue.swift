import Foundation

/// One durable draft (the note being typed right now), stored as a file so a
/// crash mid-thought loses nothing. The iOS shell debounces writes (~300ms).
public struct DraftStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private var file: URL { directory.appendingPathComponent("draft.md") }

    public func save(_ content: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // .atomic writes to a temp file and renames into place — crash durability.
        try Data(content.utf8).write(to: file, options: .atomic)
    }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try String(bytes: Data(contentsOf: file), encoding: .utf8) ?? ""
    }

    public func discard() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
    }
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

    /// Fires when a queued update landed as a conflict sibling — the shell
    /// tells the user where the copy went. Mirror of setOnCountChange.
    var onConflict: (@Sendable (_ originalPath: String, _ siblingPath: String) -> Void)?

    /// The single in-flight drain; concurrent callers share it.
    var draining: Task<DrainResult, Never>?

    public init(directory: URL) {
        self.directory = directory
    }

    public func setOnCountChange(_ handler: (@Sendable (Int) -> Void)?) {
        onCountChange = handler
    }

    public func setOnConflict(_ handler: (@Sendable (_ originalPath: String, _ siblingPath: String) -> Void)?) {
        onConflict = handler
    }

    // MARK: Enqueue / query

    public func enqueue(_ write: PendingWrite) throws {
        let entries = entriesOnDisk()
        // Dedupe: an .update for the same repo+path replaces the queued
        // .update in place (keeps FIFO position, latest content wins,
        // attempts reset). .new rows never dedupe — each is a distinct note.
        if write.kind == .update,
           let existing = entries.first(where: {
               $0.write.kind == .update && $0.write.repo == write.repo && $0.write.path == write.path
           })
        {
            var replaced = existing.write
            replaced.content = write.content
            replaced.sha = write.sha
            replaced.message = write.message
            replaced.attempts = 0
            replaced.lastError = nil
            try writeEntry(seq: existing.seq, write: replaced)
            return // count unchanged → no onCountChange
        }
        let seq = (entries.map(\.seq).max() ?? -1) + 1
        try writeEntry(seq: seq, write: write)
        emit()
    }

    public func count() -> Int {
        entriesOnDisk().count
    }

    public func rows() -> [PendingWrite] {
        entriesOnDisk().map(\.write)
    }

    /// Drop rows not belonging to `login` — runs at boot before any drain.
    public func prune(keepingRowsFor login: String) throws {
        var removed = 0
        for entry in entriesOnDisk() where entry.write.enqueuedFor != login {
            try deleteEntry(seq: entry.seq)
            removed += 1
        }
        if removed > 0 { emit() }
    }

    /// One drain runs at a time; concurrent calls share the in-flight run.
    public func drain(api: any GitHubWriting) async -> DrainResult {
        if let existing = draining { return await existing.value }
        let task = Task { await self.runDrain(api: api) }
        draining = task
        let result = await task.value
        draining = nil
        return result
    }
}

// MARK: - Drain

extension CaptureQueue {
    enum Disposition {
        case success
        case drop // other 4xx — retry can't fix it, discard the row
        case conflictResolved(siblingPath: String)
        case halt(lastError: String) // network / 5xx / rate-limited
        case unauthorized
    }

    func runDrain(api: any GitHubWriting) async -> DrainResult {
        for entry in entriesOnDisk() { // FIFO snapshot
            switch await attempt(row: entry.write, api: api) {
            case .success, .drop:
                try? deleteEntry(seq: entry.seq)
                emit()
            case let .conflictResolved(siblingPath):
                try? deleteEntry(seq: entry.seq)
                emit()
                onConflict?(entry.write.path, siblingPath)
            case let .halt(lastError):
                var updated = entry.write
                updated.attempts += 1
                updated.lastError = lastError
                try? writeEntry(seq: entry.seq, write: updated)
                return .halted(remaining: count())
            case .unauthorized:
                return .unauthorized(remaining: count()) // rows preserved as-is
            }
        }
        return .drained
    }

    private func attempt(row: PendingWrite, api: any GitHubWriting) async -> Disposition {
        do {
            switch row.kind {
            case .update:
                // Fresh SHA immediately before the PUT so a stale-editor SHA
                // never trips a 409 — only a true concurrent write does.
                let freshSHA = try await api.fileSHA(row.repo, path: row.path)
                _ = try await api.putFile(row.repo, path: row.path, content: row.content,
                                          message: row.message, sha: freshSHA)
            case .new:
                _ = try await api.putFile(row.repo, path: row.path, content: row.content,
                                          message: row.message, sha: nil)
            }
            return .success
        } catch let error as GitHubAPIError {
            return await disposition(for: error, row: row, api: api)
        } catch {
            return .halt(lastError: String(describing: error)) // unknown → halt defensively
        }
    }

    private func disposition(for error: GitHubAPIError, row: PendingWrite,
                             api: any GitHubWriting) async -> Disposition
    {
        switch error {
        case .unauthorized:
            .unauthorized
        case .conflict:
            await conflictDisposition(row: row, api: api)
        case .rateLimited, .network:
            .halt(lastError: message(for: error))
        case let .http(code, message):
            code >= 500 ? .halt(lastError: message ?? "server error \(code)") : .drop
        case .notFound, .invalidResponse:
            .drop
        }
    }

    private func message(for error: GitHubAPIError) -> String {
        switch error {
        case let .network(urlError): urlError.localizedDescription
        case .rateLimited: "rate limited"
        default: String(describing: error)
        }
    }

    private func conflictDisposition(row: PendingWrite, api: any GitHubWriting) async -> Disposition {
        // No SHA was sent for a new row — a 409 shouldn't happen. Halt rather
        // than overwrite. Only an update sibling-resolves.
        guard row.kind == .update else { return .halt(lastError: "unexpected conflict on new row") }
        return await commitConflictSibling(row: row, api: api)
    }

    /// A true concurrent write survived the fresh-SHA refetch: land the local
    /// content at the sibling path so nothing is lost, then clear the row.
    private func commitConflictSibling(row: PendingWrite, api: any GitHubWriting) async -> Disposition {
        let siblingPath = Filenames.conflictSiblingPath(row.path)
        let siblingName = (siblingPath as NSString).lastPathComponent
        do {
            _ = try await api.putFile(row.repo, path: siblingPath, content: row.content,
                                      message: CommitMessages.addConflictCopy(siblingName), sha: nil)
            return .conflictResolved(siblingPath: siblingPath)
        } catch let error as GitHubAPIError {
            // The sibling write failed for the same root cause; treat it as a
            // fresh disposition, but a repeat 409 here means halt (no overwrite).
            if case .conflict = error { return .halt(lastError: "conflict on sibling write") }
            return await disposition(for: error, row: row, api: api)
        } catch {
            return .halt(lastError: String(describing: error))
        }
    }
}

// MARK: - Persistence (one JSON file per row; seq in filename = FIFO order)

extension CaptureQueue {
    struct Entry {
        let seq: Int
        let write: PendingWrite
    }

    private func fileURL(seq: Int) -> URL {
        directory.appendingPathComponent(String(format: "%018d", seq)).appendingPathExtension("json")
    }

    /// All rows on disk, sorted by sequence (FIFO). Tolerant: an unreadable or
    /// corrupt file is skipped rather than crashing the capture path.
    func entriesOnDisk() -> [Entry] {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var entries: [Entry] = []
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "json" {
            guard let seq = Int(url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let write = try? decoder.decode(PendingWrite.self, from: data)
            else { continue }
            entries.append(Entry(seq: seq, write: write))
        }
        return entries.sorted { $0.seq < $1.seq }
    }

    func writeEntry(seq: Int, write: PendingWrite) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(write).write(to: fileURL(seq: seq), options: .atomic)
    }

    func deleteEntry(seq: Int) throws {
        let url = fileURL(seq: seq)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func emit() {
        onCountChange?(entriesOnDisk().count)
    }
}

import Foundation

#if os(macOS)

    public enum PushOutcome: Sendable, Equatable {
        case pushed
        case upToDate
        case noUpstream // tell the user: git push -u origin HEAD
        case networkError // stay unsynced; next tick retries
        case rebaseFailed // user resolves in their terminal
        case authFailed // user fixes their git credentials
        case gitError(String)
    }

    public enum PullOutcome: Sendable, Equatable {
        case pulled
        case upToDate
        case networkError
        case rebaseFailed
        case gitError(String)
    }

    public struct SaveResult: Sendable, Equatable {
        public let path: String // relative to the clone root
        public let unpushedCount: Int
        public init(path: String, unpushedCount: Int) {
            self.path = path
            self.unpushedCount = unpushedCount
        }
    }

    public enum GitSyncError: Error, Equatable {
        case invalidFilename(String) // "/" or ".." — trust boundary into a user's repo
        case git(String) // a git subprocess failed; tail of stderr
    }

    /// One run of `/usr/bin/git`: exit code plus captured streams.
    private struct GitRun {
        let code: Int32
        let out: String
        let err: String
    }

    /// The Mac save path — trailhead's Tauri design, verbatim:
    /// the app operates on the user's existing local clone.
    ///  - draft   = an untracked timestamped .md in the capture subfolder,
    ///              written atomically (tmp + rename); recovery = newest one
    ///  - save    = atomic write + `git add` + `git commit` (durable locally)
    ///  - queue   = unpushed commits (rev-list @{u}..HEAD) — no separate store
    ///  - push    = background retry; on non-fast-forward rejection runs
    ///              `git pull --rebase --autostash` then pushes again
    ///  - pull    = same rebase pull, run on a user-configured cadence
    ///  - push uses the user's own git credentials (ssh key / helper) — the
    ///    GitHub token is never injected into git
    /// All git runs shell out to /usr/bin/git via Process, serialized by the
    /// actor — one git operation at a time per clone.
    public actor GitSync {
        public let clone: URL
        /// Capture subfolder relative to the clone root ("" = root).
        public let subfolder: String

        public init(clone: URL, subfolder: String) {
            self.clone = clone
            self.subfolder = subfolder
        }

        // MARK: Drafts

        public func writeDraft(filename: String, content: String) throws {
            let url = try captureURL(filename)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
        }

        /// Newest untracked capture draft in the subfolder, if any (crash recovery).
        public func latestDraft() throws -> (filename: String, content: String)? {
            let newest = try untrackedMarkdown()
                .map { (path: $0, mtime: modifiedAt(clone.appendingPathComponent($0))) }
                .max { $0.mtime < $1.mtime }
            guard let newest else { return nil }
            let url = clone.appendingPathComponent(newest.path)
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            return ((newest.path as NSString).lastPathComponent, String(bytes: data, encoding: .utf8) ?? "")
        }

        public func discardDraft(filename: String) throws {
            let url = try captureURL(filename)
            let manager = FileManager.default
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }

        // MARK: Save + sync

        /// Atomic write + add + commit. `message` defaults to CommitMessages.add.
        public func saveCapture(filename: String, content: String,
                                message: String? = nil) throws -> SaveResult
        {
            let url = try captureURL(filename)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)

            let rel = relativePath(filename)
            let add = git(["add", "--", rel])
            guard add.code == 0 else { throw GitSyncError.git(tail(add.err)) }
            let commit = git(["commit", "-m", message ?? CommitMessages.add(filename)])
            guard commit.code == 0 else { throw GitSyncError.git(tail(commit.err)) }

            return try SaveResult(path: rel, unpushedCount: unpushedCount())
        }

        public func unpushedCount() throws -> Int {
            let run = git(["rev-list", "--count", "@{u}..HEAD"])
            // No upstream configured → 0; tryPush surfaces .noUpstream instead.
            guard run.code == 0 else { return 0 }
            return Int(run.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        public func tryPush() async -> PushOutcome {
            // pushOutcome returns nil for a non-fast-forward rejection → rebase.
            if let outcome = pushOutcome(git(["push"])) { return outcome }
            let pull = git(["pull", "--rebase", "--autostash"])
            guard pull.code == 0 else {
                // Deliberate deviation from trailhead: abort so the working tree
                // is left clean, rather than mid-rebase.
                _ = git(["rebase", "--abort"])
                return .rebaseFailed
            }
            return pushOutcome(git(["push"])) ?? .gitError("rebase succeeded but push still rejected")
        }

        /// `git pull --rebase --autostash` — the cadence pull.
        public func pull() async -> PullOutcome {
            let run = git(["pull", "--rebase", "--autostash"])
            if run.code == 0 {
                return (run.out + run.err).lowercased().contains("up to date") ? .upToDate : .pulled
            }
            let lowered = run.err.lowercased()
            if isNetwork(lowered) { return .networkError }
            // A conflicting edit left a rebase in progress — abort to a clean tree.
            _ = git(["rebase", "--abort"])
            if lowered.contains("conflict") || lowered.contains("could not apply") {
                return .rebaseFailed
            }
            return .gitError(tail(run.err))
        }

        /// Sanity check for settings: is `clone` actually a git repo with a remote?
        public static func validateClone(at url: URL) -> Bool {
            let inside = runGit(at: url, ["rev-parse", "--is-inside-work-tree"])
            guard inside.code == 0,
                  inside.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return false }
            let remotes = runGit(at: url, ["remote"])
            guard remotes.code == 0 else { return false }
            return remotes.out.split(separator: "\n").contains("origin")
        }
    }

    // MARK: - Helpers

    private extension GitSync {
        /// `<clone>/<subfolder>/<filename>` after rejecting traversal. This
        /// writes into a user's repo, so the filename is a hard trust boundary.
        func captureURL(_ filename: String) throws -> URL {
            guard !filename.isEmpty, !filename.contains("/"), !filename.contains("..") else {
                throw GitSyncError.invalidFilename(filename)
            }
            var url = clone
            for part in subfolder.split(separator: "/") { url.appendPathComponent(String(part)) }
            return url.appendingPathComponent(filename)
        }

        /// Repo-relative path for a capture file (matches git's own output).
        func relativePath(_ filename: String) -> String {
            let sub = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return sub.isEmpty ? filename : "\(sub)/\(filename)"
        }

        /// Untracked `.md` files directly inside the subfolder (not nested),
        /// as repo-relative paths. `?? path` porcelain entries only.
        func untrackedMarkdown() throws -> [String] {
            var args = ["status", "--porcelain", "-uall"]
            if !subfolder.isEmpty { args += ["--", subfolder] }
            let run = git(args)
            guard run.code == 0 else { throw GitSyncError.git(tail(run.err)) }
            return run.out
                .split(separator: "\n")
                .filter { $0.hasPrefix("?? ") }
                .map { String($0.dropFirst(3)) }
                .filter(isDirectChildDraft)
        }

        /// A `.md` directly inside the subfolder (not in a nested folder).
        func isDirectChildDraft(_ path: String) -> Bool {
            guard path.hasSuffix(".md") else { return false }
            let trimmedSub = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefix = trimmedSub.isEmpty ? "" : trimmedSub + "/"
            if prefix.isEmpty { return !path.contains("/") }
            guard path.hasPrefix(prefix) else { return false }
            return !path.dropFirst(prefix.count).contains("/")
        }

        func modifiedAt(_ url: URL) -> Date {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.modificationDate] as? Date) ?? .distantPast
        }

        func git(_ args: [String]) -> GitRun { Self.runGit(at: clone, args) }

        /// Run `/usr/bin/git -C <clone> <args>`, capturing stdout/stderr.
        /// ponytail: reads stdout then stderr sequentially — safe because these
        /// git commands emit well under the 64 KB pipe buffer. If a push ever
        /// floods stderr with progress, switch to concurrent pipe reads.
        static func runGit(at clone: URL, _ args: [String]) -> GitRun {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", clone.path] + args
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                return GitRun(code: -1, out: "", err: "spawn git: \(error.localizedDescription)")
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return GitRun(code: process.terminationStatus,
                          out: String(bytes: outData, encoding: .utf8) ?? "",
                          err: String(bytes: errData, encoding: .utf8) ?? "")
        }

        func tail(_ stderr: String) -> String {
            stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Terminal push outcome, or nil for a non-fast-forward rejection
        /// (the caller then rebases and retries). Auth is checked before the
        /// network shapes because an HTTPS 403 also mentions "unable to access".
        func pushOutcome(_ run: GitRun) -> PushOutcome? {
            let trimmed = tail(run.err)
            if run.code == 0 {
                return trimmed.contains("Everything up-to-date") ? .upToDate : .pushed
            }
            let lowered = trimmed.lowercased()
            if lowered.contains("no upstream") || lowered.contains("has no upstream") { return .noUpstream }
            if lowered.contains("non-fast-forward") || lowered.contains("updates were rejected")
                || lowered.contains("fetch first") || lowered.contains("[rejected]") { return nil }
            if lowered.contains("authentication failed") || lowered.contains("permission denied")
                || lowered.contains("invalid username or password") || lowered.contains("could not read username")
                || lowered.contains("403") { return .authFailed }
            if isNetwork(lowered) { return .networkError }
            return .gitError(trimmed)
        }

        func isNetwork(_ lowercasedStderr: String) -> Bool {
            lowercasedStderr.contains("could not resolve host")
                || lowercasedStderr.contains("unable to access")
                || lowercasedStderr.contains("connection timed out")
                || lowercasedStderr.contains("network is unreachable")
                || lowercasedStderr.contains("temporary failure in name resolution")
                || lowercasedStderr.contains("connection refused")
        }
    }

#endif

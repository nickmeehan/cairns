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

        public func writeDraft(filename _: String, content _: String) throws {
            fatalError("unimplemented")
        }

        /// Newest untracked capture draft in the subfolder, if any (crash recovery).
        public func latestDraft() throws -> (filename: String, content: String)? {
            fatalError("unimplemented")
        }

        public func discardDraft(filename _: String) throws {
            fatalError("unimplemented")
        }

        // MARK: Save + sync

        /// Atomic write + add + commit. `message` defaults to CommitMessages.add.
        public func saveCapture(filename _: String, content _: String, message _: String? = nil) throws -> SaveResult {
            fatalError("unimplemented")
        }

        public func unpushedCount() throws -> Int {
            fatalError("unimplemented")
        }

        public func tryPush() async -> PushOutcome {
            fatalError("unimplemented")
        }

        /// `git pull --rebase --autostash` — the cadence pull.
        public func pull() async -> PullOutcome {
            fatalError("unimplemented")
        }

        /// Sanity check for settings: is `clone` actually a git repo with a remote?
        public static func validateClone(at _: URL) -> Bool {
            fatalError("unimplemented")
        }
    }

#endif

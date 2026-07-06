#if os(macOS)

    import CairnsKit
    import XCTest

    /// One run of git in the test harness.
    private struct GitOutput {
        let code: Int32
        let out: String
        let err: String
    }

    /// Hermetic git fixtures: a bare "remote" plus one or more clones over a
    /// file:// URL. No network, every test < 1s.
    final class GitSyncTests: XCTestCase {
        private var scratch: URL!

        override func setUpWithError() throws {
            scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("cairns-gitsync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: scratch)
        }

        // MARK: saveCapture

        func testSaveCaptureCommitsFileWithMessage() async throws {
            let clone = cloneWithSeed(makeBareRemote())
            let sync = GitSync(clone: clone, subfolder: "inbox")

            let result = try await sync.saveCapture(filename: "2026-05-02-120000.md",
                                                    content: "captured thought",
                                                    message: "Add: 2026-05-02-120000.md")
            XCTAssertEqual(result.path, "inbox/2026-05-02-120000.md")

            // File on disk, working tree clean (committed).
            XCTAssertEqual(read(clone.appendingPathComponent("inbox/2026-05-02-120000.md")),
                           "captured thought")
            XCTAssertTrue(git(clone, ["status", "--porcelain"]).out.isEmpty)

            // Commit message landed.
            XCTAssertTrue(git(clone, ["log", "--oneline"]).out.contains("Add: 2026-05-02-120000.md"))
        }

        func testSaveCaptureAtRepoRoot() async throws {
            let clone = cloneWithSeed(makeBareRemote())
            let sync = GitSync(clone: clone, subfolder: "")
            let result = try await sync.saveCapture(filename: "root.md", content: "x",
                                                    message: "Add: root.md")
            XCTAssertEqual(result.path, "root.md")
            XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appendingPathComponent("root.md").path))
        }

        // MARK: unpushedCount + tryPush

        func testUnpushedCountBeforeAndAfterPush() async throws {
            let clone = cloneWithSeed(makeBareRemote())
            let sync = GitSync(clone: clone, subfolder: "inbox")

            var count = try await sync.unpushedCount()
            XCTAssertEqual(count, 0) // seed already pushed

            _ = try await sync.saveCapture(filename: "a.md", content: "a", message: "Add: a.md")
            count = try await sync.unpushedCount()
            XCTAssertEqual(count, 1)

            let outcome = await sync.tryPush()
            XCTAssertEqual(outcome, .pushed)
            count = try await sync.unpushedCount()
            XCTAssertEqual(count, 0)

            let again = await sync.tryPush()
            XCTAssertEqual(again, .upToDate) // nothing left to push
        }

        func testTryPushRebasesWhenRemoteMoved() async throws {
            let bare = makeBareRemote()
            let cloneA = cloneWithSeed(bare)
            let cloneB = cloneWithSeed(bare)
            let syncA = GitSync(clone: cloneA, subfolder: "")
            let syncB = GitSync(clone: cloneB, subfolder: "")

            // B pushes first — distinct timestamped filename.
            _ = try await syncB.saveCapture(filename: "from-b.md", content: "b", message: "Add: from-b.md")
            let pushB = await syncB.tryPush()
            XCTAssertEqual(pushB, .pushed)

            // A commits on the stale base; tryPush must rebase, then push.
            _ = try await syncA.saveCapture(filename: "from-a.md", content: "a", message: "Add: from-a.md")
            let pushA = await syncA.tryPush()
            XCTAssertEqual(pushA, .pushed)
            let remaining = try await syncA.unpushedCount()
            XCTAssertEqual(remaining, 0)

            // A now has both commits after the rebase.
            let log = git(cloneA, ["log", "--oneline"]).out
            XCTAssertTrue(log.contains("Add: from-a.md"), log)
            XCTAssertTrue(log.contains("Add: from-b.md"), log)
        }

        func testTryPushNoUpstream() async throws {
            // origin exists, but the branch has no upstream tracking configured
            // — `git push` refuses with "has no upstream branch".
            let bare = makeBareRemote()
            let clone = scratch.appendingPathComponent("no-upstream")
            try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
            git(clone, ["init", "-q", "-b", "main"])
            git(clone, ["config", "user.email", "t@t"])
            git(clone, ["config", "user.name", "t"])
            git(clone, ["config", "push.default", "simple"]) // refuse push without upstream
            git(clone, ["remote", "add", "origin", "file://\(bare.path)"])
            let sync = GitSync(clone: clone, subfolder: "")
            _ = try await sync.saveCapture(filename: "a.md", content: "a", message: "Add: a.md")

            let outcome = await sync.tryPush()
            XCTAssertEqual(outcome, .noUpstream)
            let count = try await sync.unpushedCount()
            XCTAssertEqual(count, 0) // no upstream tracking → 0, not total
        }

        func testTryPushRebaseFailedLeavesCleanTree() async throws {
            let bare = makeBareRemote()
            let cloneA = cloneWithSeed(bare)
            let cloneB = cloneWithSeed(bare)
            let syncA = GitSync(clone: cloneA, subfolder: "")
            let syncB = GitSync(clone: cloneB, subfolder: "")

            // Both edit the SAME committed file with conflicting content, so the
            // rebase genuinely fails (not Cairns' usual distinct filenames).
            _ = try await syncB.saveCapture(filename: "README.md", content: "from B\n", message: "Update from B")
            let pushB = await syncB.tryPush()
            XCTAssertEqual(pushB, .pushed)

            _ = try await syncA.saveCapture(filename: "README.md", content: "from A\n", message: "Update from A")
            let pushA = await syncA.tryPush()
            XCTAssertEqual(pushA, .rebaseFailed)

            // The abort restored a clean working tree (no rebase in progress).
            XCTAssertTrue(git(cloneA, ["status", "--porcelain"]).out.isEmpty,
                          "expected clean tree after rebase --abort")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: cloneA.appendingPathComponent(".git/rebase-merge").path))
        }
    }

    // MARK: - Draft / pull / validate tests

    extension GitSyncTests {
        func testDraftWriteRecoverDiscard() async throws {
            let clone = cloneWithSeed(makeBareRemote())
            let sync = GitSync(clone: clone, subfolder: "inbox")

            let empty = try await sync.latestDraft()
            XCTAssertNil(empty)

            try await sync.writeDraft(filename: "2026-05-02-100000.md", content: "older")
            // Ensure a distinct mtime for deterministic newest-selection.
            try await Task.sleep(nanoseconds: 20_000_000)
            try await sync.writeDraft(filename: "2026-05-02-110000.md", content: "newer")

            let latest = try await sync.latestDraft()
            XCTAssertEqual(latest?.filename, "2026-05-02-110000.md")
            XCTAssertEqual(latest?.content, "newer")

            try await sync.discardDraft(filename: "2026-05-02-110000.md")
            let afterDiscard = try await sync.latestDraft()
            XCTAssertEqual(afterDiscard?.filename, "2026-05-02-100000.md")
        }

        func testDraftIgnoresCommittedAndNestedAndNonMarkdown() async throws {
            let clone = cloneWithSeed(makeBareRemote())
            let sync = GitSync(clone: clone, subfolder: "inbox")

            // Committed .md — not a draft.
            try await sync.saveCapture(filename: "committed.md", content: "real", message: "Add: committed.md")
            // Untracked non-md, nested md, and md outside the subfolder — none are drafts.
            FileManager.default.createFile(atPath: clone.appendingPathComponent("inbox/note.txt").path,
                                           contents: Data("skip".utf8))
            try FileManager.default.createDirectory(
                at: clone.appendingPathComponent("inbox/nested"), withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: clone.appendingPathComponent("inbox/nested/deep.md").path,
                                           contents: Data("skip".utf8))
            FileManager.default.createFile(atPath: clone.appendingPathComponent("elsewhere.md").path,
                                           contents: Data("skip".utf8))
            // One genuine draft.
            try await sync.writeDraft(filename: "draft.md", content: "keep")

            let latest = try await sync.latestDraft()
            XCTAssertEqual(latest?.filename, "draft.md")
            XCTAssertEqual(latest?.content, "keep")
        }

        func testWriteDraftRejectsUnsafeFilenames() async throws {
            let clone = cloneWithSeed(makeBareRemote())
            let sync = GitSync(clone: clone, subfolder: "inbox")
            for bad in ["../escape.md", "sub/dir.md", ".."] {
                do {
                    try await sync.writeDraft(filename: bad, content: "x")
                    XCTFail("expected rejection for \(bad)")
                } catch let GitSyncError.invalidFilename(name) {
                    XCTAssertEqual(name, bad)
                }
            }
        }

        func testPullUpToDateThenPulls() async throws {
            let bare = makeBareRemote()
            let cloneA = cloneWithSeed(bare)
            let cloneB = cloneWithSeed(bare)
            let syncA = GitSync(clone: cloneA, subfolder: "")
            let syncB = GitSync(clone: cloneB, subfolder: "")

            let upToDate = await syncA.pull()
            XCTAssertEqual(upToDate, .upToDate)

            // B pushes a distinct file; A pulls it down cleanly.
            _ = try await syncB.saveCapture(filename: "from-b.md", content: "b", message: "Add: from-b.md")
            let pushB = await syncB.tryPush()
            XCTAssertEqual(pushB, .pushed)

            let pulled = await syncA.pull()
            XCTAssertEqual(pulled, .pulled)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cloneA.appendingPathComponent("from-b.md").path))
        }

        func testValidateClone() async throws {
            let clone = cloneWithSeed(makeBareRemote())
            XCTAssertTrue(GitSync.validateClone(at: clone)) // work tree + origin remote

            // A git repo with no remote fails validation.
            let noRemote = scratch.appendingPathComponent("bare-solo")
            try FileManager.default.createDirectory(at: noRemote, withIntermediateDirectories: true)
            git(noRemote, ["init", "-q", "-b", "main"])
            XCTAssertFalse(GitSync.validateClone(at: noRemote))

            // A plain directory (no git) fails validation.
            let plain = scratch.appendingPathComponent("plain")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            XCTAssertFalse(GitSync.validateClone(at: plain))
        }
    }

    // MARK: - git fixtures

    extension GitSyncTests {
        @discardableResult
        private func git(_ dir: URL, _ args: [String]) -> GitOutput {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", dir.path] + args
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try? process.run()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return GitOutput(code: process.terminationStatus,
                             out: String(bytes: out, encoding: .utf8) ?? "",
                             err: String(bytes: err, encoding: .utf8) ?? "")
        }

        private func makeBareRemote() -> URL {
            let bare = scratch.appendingPathComponent("remote-\(UUID().uuidString).git")
            let result = git(scratch, ["init", "--bare", "-q", "-b", "main", bare.path])
            XCTAssertEqual(result.code, 0, result.err)
            return bare
        }

        /// Clone `bare`, configure identity, seed one commit, push with upstream.
        private func cloneWithSeed(_ bare: URL) -> URL {
            let work = scratch.appendingPathComponent("clone-\(UUID().uuidString)")
            XCTAssertEqual(git(scratch, ["clone", "-q", "file://\(bare.path)", work.path]).code, 0)
            git(work, ["config", "user.email", "t@t"])
            git(work, ["config", "user.name", "t"])
            FileManager.default.createFile(atPath: work.appendingPathComponent("README.md").path,
                                           contents: Data("seed".utf8))
            git(work, ["add", "README.md"])
            git(work, ["commit", "-q", "-m", "seed"])
            git(work, ["push", "-q", "-u", "origin", "main"])
            return work
        }

        private func read(_ url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

#endif

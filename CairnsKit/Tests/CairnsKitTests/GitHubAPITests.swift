@testable import CairnsKit
import XCTest

/// Shared fixtures for the GitHubAPI suites (kept in a base class so each
/// concrete suite stays under SwiftLint's type-body-length wall).
class GitHubAPITestCase: XCTestCase {
    let repo = RepoRef(owner: "alice", name: "notes")

    func api() -> GitHubAPI {
        GitHubAPI(token: "ghu_test_token", session: StubURLProtocol.makeSession())
    }

    func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    func decodedBase64(_ base64: String) throws -> String {
        try XCTUnwrap(String(bytes: XCTUnwrap(Data(base64Encoded: base64)), encoding: .utf8))
    }
}

/// GitHubAPI verb coverage — happy paths + request shape. Network is stubbed
/// via URLProtocol; every assertion is offline and deterministic.
final class GitHubAPITests: GitHubAPITestCase {
    // MARK: user + headers

    func testUserParsesLoginAndSendsHeaders() async throws {
        StubURLProtocol.box.load([.json(200, ["login": "alice", "id": 1, "name": "Alice"])])
        let user = try await api().user()
        XCTAssertEqual(user, GitHubUser(login: "alice"))

        let request = try XCTUnwrap(StubURLProtocol.box.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(request.headers["Authorization"], "Bearer ghu_test_token")
        XCTAssertEqual(request.headers["Accept"], "application/vnd.github+json")
        XCTAssertEqual(request.headers["X-GitHub-Api-Version"], "2022-11-28")
    }

    // MARK: repositories

    func testRepositoriesMapsAndSendsQuery() async throws {
        StubURLProtocol.box.load([.json(200, [
            ["name": "notes", "owner": ["login": "alice"]],
            ["name": "blog", "owner": ["login": "alice"]],
        ])])
        let repos = try await api().repositories()
        XCTAssertEqual(repos, [RepoRef(owner: "alice", name: "notes"),
                               RepoRef(owner: "alice", name: "blog")])

        let url = try XCTUnwrap(StubURLProtocol.box.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://api.github.com/user/repos?"), url)
        XCTAssertTrue(url.contains("affiliation=owner"), url)
        XCTAssertTrue(url.contains("sort=pushed"), url)
        XCTAssertTrue(url.contains("per_page=100"), url)
    }

    // MARK: listFolder

    func testListFolderMarksDirectories() async throws {
        StubURLProtocol.box.load([.json(200, [
            ["name": "a.md", "path": "notes/a.md", "sha": "s1", "type": "file"],
            ["name": "sub", "path": "notes/sub", "sha": "s2", "type": "dir"],
        ])])
        let files = try await api().listFolder(repo, path: "notes")
        XCTAssertEqual(files, [
            RepoFile(name: "a.md", path: "notes/a.md", sha: "s1", isDirectory: false),
            RepoFile(name: "sub", path: "notes/sub", sha: "s2", isDirectory: true),
        ])
    }

    func testListFolderRootPath() async throws {
        StubURLProtocol.box.load([.json(200, [[String: Any]]())])
        _ = try await api().listFolder(repo, path: "")
        XCTAssertEqual(StubURLProtocol.box.requests.first?.url?.absoluteString,
                       "https://api.github.com/repos/alice/notes/contents/")
    }

    func testListFolder404IsEmptyNotError() async throws {
        StubURLProtocol.box.load([.text(404, "Not Found")])
        let files = try await api().listFolder(repo, path: "new-folder")
        XCTAssertEqual(files, [])
    }

    // MARK: fileContent

    func testFileContentDecodesAsciiAndReturnsSHA() async throws {
        StubURLProtocol.box.load([.json(200, [
            "content": base64("Hello, world!"), "sha": "abc123", "encoding": "base64",
        ])])
        let result = try await api().fileContent(repo, path: "test.md")
        XCTAssertEqual(result.content, "Hello, world!")
        XCTAssertEqual(result.sha, "abc123")
    }

    func testFileContentStripsNewlinesInBase64() async throws {
        // GitHub wraps base64 with \n; decoding must ignore the breaks.
        let raw = base64("A line of content that is long enough to wrap")
        let wrapped = String(raw.prefix(20)) + "\n" + String(raw.dropFirst(20))
        StubURLProtocol.box.load([.json(200, ["content": wrapped, "sha": "s", "encoding": "base64"])])
        let result = try await api().fileContent(repo, path: "test.md")
        XCTAssertEqual(result.content, "A line of content that is long enough to wrap")
    }

    func testFileContentDecodesUTF8() async throws {
        let text = "Café ☕ 😀"
        StubURLProtocol.box.load([.json(200, ["content": base64(text), "sha": "s", "encoding": "base64"])])
        let result = try await api().fileContent(repo, path: "u.md")
        XCTAssertEqual(result.content, text)
    }

    // MARK: fileSHA

    func testFileSHAReturnsSHA() async throws {
        StubURLProtocol.box.load([.json(200, ["sha": "abc123"])])
        let sha = try await api().fileSHA(repo, path: "test.md")
        XCTAssertEqual(sha, "abc123")
    }

    func testFileSHA404IsNil() async throws {
        StubURLProtocol.box.load([.text(404, "Not Found")])
        let sha = try await api().fileSHA(repo, path: "missing.md")
        XCTAssertNil(sha)
    }

    // MARK: putFile

    func testPutFileCreateOmitsSHA() async throws {
        StubURLProtocol.box.load([.json(200, [
            "content": ["name": "new.md", "path": "new.md", "sha": "new_sha"],
            "commit": ["sha": "c", "message": "m"],
        ])])
        let result = try await api().putFile(repo, path: "new.md", content: "Hello!",
                                             message: "Add: new.md", sha: nil)
        XCTAssertEqual(result, CommitResult(path: "new.md", contentSHA: "new_sha"))

        let request = try XCTUnwrap(StubURLProtocol.box.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/alice/notes/contents/new.md")
        XCTAssertEqual(request.bodyJSON["message"] as? String, "Add: new.md")
        XCTAssertNil(request.bodyJSON["sha"], "create must omit sha")
        XCTAssertEqual(try decodedBase64(XCTUnwrap(request.bodyJSON["content"] as? String)), "Hello!")
    }

    func testPutFileUpdateIncludesSHA() async throws {
        StubURLProtocol.box.load([.json(200, [
            "content": ["name": "f", "path": "existing.md", "sha": "s2"],
            "commit": ["sha": "c", "message": "m"],
        ])])
        _ = try await api().putFile(repo, path: "existing.md", content: "Updated",
                                    message: "Update: existing.md", sha: "old_sha")
        let body = try XCTUnwrap(StubURLProtocol.box.requests.first).bodyJSON
        XCTAssertEqual(body["sha"] as? String, "old_sha")
    }

    func testPutFileEncodesUTF8Content() async throws {
        StubURLProtocol.box.load([.json(200, [
            "content": ["name": "f", "path": "u.md", "sha": "s"],
            "commit": ["sha": "c", "message": "m"],
        ])])
        let text = "Café ☕ 😀"
        _ = try await api().putFile(repo, path: "u.md", content: text, message: "m", sha: nil)
        let content = try XCTUnwrap(StubURLProtocol.box.requests.first?.bodyJSON["content"] as? String)
        XCTAssertEqual(try decodedBase64(content), text)
    }

    func testPutFilePercentEncodesPathSegments() async throws {
        StubURLProtocol.box.load([.json(200, [
            "content": ["name": "f", "path": "notes/my note.md", "sha": "s"],
            "commit": ["sha": "c", "message": "m"],
        ])])
        _ = try await api().putFile(repo, path: "notes/my nöte.md", content: "x", message: "m", sha: nil)
        let url = try XCTUnwrap(StubURLProtocol.box.requests.first?.url?.absoluteString)
        XCTAssertFalse(url.contains(" "), "spaces must be percent-encoded: \(url)")
        XCTAssertTrue(url.contains("my%20n"), url)
    }
}

/// The auth-reliability error contract: which status maps to which case.
final class GitHubAPIErrorTests: GitHubAPITestCase {
    func testUnauthorizedMapsTo401() async {
        await assertUserError(status: 401, tag: "unauthorized")
    }

    func testForbiddenIsRateLimitedNotAuthFailure() async {
        // The whole point: a 403 must NEVER sign the user out.
        await assertUserError(status: 403, tag: "rateLimited")
    }

    func testTooManyRequestsIsRateLimited() async {
        await assertUserError(status: 429, tag: "rateLimited")
    }

    func testNotFoundMaps() async {
        await assertUserError(status: 404, tag: "notFound")
    }

    func testConflictMaps() async {
        await assertUserError(status: 409, tag: "conflict")
    }

    func testFileSHANon404Throws() async {
        StubURLProtocol.box.load([.text(500, "boom")])
        let error = await thrownError { try await api().fileSHA(repo, path: "x.md") }
        XCTAssertEqual((error as? GitHubAPIError)?.tag, "http(500)")
    }

    func testOtherStatusCarriesMessage() async {
        StubURLProtocol.box.load([.text(503, "unavailable")])
        let error = await thrownError { try await api().user() }
        guard case let .http(status, message) = (error as? GitHubAPIError) else {
            return XCTFail("expected .http, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 503)
        XCTAssertEqual(message, "unavailable")
    }

    func testURLErrorMapsToNetwork() async {
        StubURLProtocol.box.load([.failure(.notConnectedToInternet)])
        let error = await thrownError { try await api().user() }
        XCTAssertEqual((error as? GitHubAPIError)?.tag, "network")
    }

    func testMalformedJSONMapsToInvalidResponse() async {
        StubURLProtocol.box.load([.text(200, "{ not json")])
        let error = await thrownError { try await api().user() }
        XCTAssertEqual((error as? GitHubAPIError)?.tag, "invalidResponse")
    }

    private func assertUserError(status: Int, tag: String) async {
        StubURLProtocol.box.load([.text(status, "err")])
        let error = await thrownError { try await api().user() }
        XCTAssertEqual((error as? GitHubAPIError)?.tag, tag)
    }
}

/// Stable string tag for asserting error cases (GitHubAPIError isn't Equatable).
extension GitHubAPIError {
    var tag: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .conflict: "conflict"
        case .notFound: "notFound"
        case .rateLimited: "rateLimited"
        case let .http(status, _): "http(\(status))"
        case .network: "network"
        case .invalidResponse: "invalidResponse"
        }
    }
}

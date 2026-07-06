import Foundation

public struct GitHubUser: Sendable, Equatable, Codable {
    public let login: String
    public init(login: String) { self.login = login }
}

public struct RepoRef: Sendable, Equatable, Codable, Hashable {
    public let owner: String
    public let name: String
    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }
}

public struct RepoFile: Sendable, Equatable {
    public let name: String
    public let path: String
    public let sha: String
    public let isDirectory: Bool
    public init(name: String, path: String, sha: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.sha = sha
        self.isDirectory = isDirectory
    }
}

public struct CommitResult: Sendable, Equatable {
    /// Path the content actually landed at (differs from the request on a
    /// 409 → conflict-sibling write).
    public let path: String
    /// New blob SHA of the file content.
    public let contentSHA: String
    public init(path: String, contentSHA: String) {
        self.path = path
        self.contentSHA = contentSHA
    }
}

public enum GitHubAPIError: Error {
    case unauthorized // 401 — token dead; halt queues, route to re-auth
    case conflict // 409 — real concurrent write (after fresh SHA)
    case notFound // 404
    case rateLimited // 403/429 rate-limit shapes — NOT an auth failure
    case http(Int, message: String?)
    case network(URLError)
    case invalidResponse(String)
}

/// The write seam CaptureQueue drains through — lets the queue be tested
/// against a fake without a URLSession.
public protocol GitHubWriting: Sendable {
    func fileSHA(_ repo: RepoRef, path: String) async throws -> String?
    func putFile(_ repo: RepoRef, path: String, content: String, message: String,
                 sha: String?) async throws -> CommitResult
}

/// Minimal GitHub REST client — exactly the calls Cairns makes, nothing more.
/// All writes go through the Contents API; capture notes are small.
/// ponytail: no Git Data API large-file path — Contents API PUT handles up
/// to a few MB; add the blob→tree→commit chain only if real notes hit it.
public struct GitHubAPI: GitHubWriting, Sendable {
    public let token: String
    let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// GET /user — identifies the login for queue scoping and token checks.
    public func user() async throws -> GitHubUser {
        fatalError("unimplemented")
    }

    /// GET /user/repos (affiliation=owner, sorted by pushed) — repo picker.
    public func repositories() async throws -> [RepoRef] {
        fatalError("unimplemented")
    }

    /// GET /repos/{owner}/{repo}/contents/{path} on a directory.
    /// Empty path = repo root. 404 on an empty/new folder returns [].
    public func listFolder(_: RepoRef, path _: String) async throws -> [RepoFile] {
        fatalError("unimplemented")
    }

    /// GET one file's decoded content + current SHA.
    public func fileContent(_: RepoRef, path _: String) async throws -> (content: String, sha: String) {
        fatalError("unimplemented")
    }

    /// Current SHA for a path, nil when the file doesn't exist. Always called
    /// immediately before an update PUT so stale-editor 409s never happen —
    /// only true concurrent writes surface as .conflict.
    public func fileSHA(_: RepoRef, path _: String) async throws -> String? {
        fatalError("unimplemented")
    }

    /// PUT /repos/{owner}/{repo}/contents/{path}. sha nil = create ("Add:"),
    /// sha set = update ("Update:"). Throws .conflict on 409.
    public func putFile(_: RepoRef, path _: String, content _: String, message _: String,
                        sha _: String?) async throws -> CommitResult
    {
        fatalError("unimplemented")
    }
}

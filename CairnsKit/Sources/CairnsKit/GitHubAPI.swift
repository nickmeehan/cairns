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
        try await decode(GitHubUser.self, from: perform(get("/user")))
    }

    /// GET /user/repos (affiliation=owner, sorted by pushed) — repo picker.
    public func repositories() async throws -> [RepoRef] {
        // ponytail: single page (per_page=100). Add pagination when a real
        // user owns >100 repos — until then the extra round-trips are waste.
        let request = get("/user/repos", query: [
            URLQueryItem(name: "affiliation", value: "owner"),
            URLQueryItem(name: "sort", value: "pushed"),
            URLQueryItem(name: "per_page", value: "100"),
        ])
        return try await decode([RepoDTO].self, from: perform(request))
            .map { RepoRef(owner: $0.owner.login, name: $0.name) }
    }

    /// GET /repos/{owner}/{repo}/contents/{path} on a directory.
    /// Empty path = repo root. 404 on an empty/new folder returns [].
    public func listFolder(_ repo: RepoRef, path: String) async throws -> [RepoFile] {
        do {
            let items = try await decodeContents(from: perform(get(contentsEndpoint(repo, path))))
            return items.map {
                RepoFile(name: $0.name, path: $0.path, sha: $0.sha, isDirectory: $0.type == "dir")
            }
        } catch GitHubAPIError.notFound {
            return [] // an empty/new folder is not an error for a capture app
        }
    }

    /// GET one file's decoded content + current SHA.
    public func fileContent(_ repo: RepoRef, path: String) async throws -> (content: String, sha: String) {
        let file = try await decode(FileDTO.self, from: perform(get(contentsEndpoint(repo, path))))
        // ponytail: no Blobs API fallback for >1 MB (encoding "none") — capture
        // notes are small (docs/decisions.md). If it ever fires the note stays
        // queued and this surfaces as .invalidResponse rather than corrupting.
        guard let base64 = file.content, let text = Self.decodeBase64UTF8(base64) else {
            throw GitHubAPIError.invalidResponse("undecodable file content at \(path)")
        }
        return (text, file.sha)
    }

    /// Current SHA for a path, nil when the file doesn't exist. Always called
    /// immediately before an update PUT so stale-editor 409s never happen —
    /// only true concurrent writes surface as .conflict.
    public func fileSHA(_ repo: RepoRef, path: String) async throws -> String? {
        do {
            return try await decode(SHADTO.self, from: perform(get(contentsEndpoint(repo, path)))).sha
        } catch GitHubAPIError.notFound {
            return nil
        }
    }

    /// PUT /repos/{owner}/{repo}/contents/{path}. sha nil = create ("Add:"),
    /// sha set = update ("Update:"). Throws .conflict on 409.
    public func putFile(_ repo: RepoRef, path: String, content: String, message: String,
                        sha: String?) async throws -> CommitResult
    {
        var payload: [String: Any] = [
            "message": message,
            "content": Data(content.utf8).base64EncodedString(),
        ]
        if let sha { payload["sha"] = sha } // omitted on create, per the contract
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = request("PUT", contentsEndpoint(repo, path), body: body)
        let result = try await decode(CommitDTO.self, from: perform(request))
        return CommitResult(path: result.content.path, contentSHA: result.content.sha)
    }

    // MARK: - Transport

    private static let baseURL = "https://api.github.com"
    private static let fallbackURL = URL(fileURLWithPath: "/")

    private func contentsEndpoint(_ repo: RepoRef, _ path: String) -> String {
        "/repos/\(repo.owner)/\(repo.name)/contents/\(path)"
    }

    private func get(_ endpoint: String, query: [URLQueryItem] = []) -> URLRequest {
        request("GET", endpoint, query: query, body: nil)
    }

    private func request(_ method: String, _ endpoint: String,
                         query: [URLQueryItem] = [], body: Data?) -> URLRequest
    {
        // URLComponents percent-encodes the path, so spaces/unicode in a
        // filename land as %20 / %C3%B6 rather than breaking the URL.
        var comps = URLComponents(string: Self.baseURL)
        comps?.path = endpoint
        if !query.isEmpty { comps?.queryItems = query }
        var req = URLRequest(url: comps?.url ?? Self.fallbackURL)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw GitHubAPIError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw Self.mapError(status, data) }
        return data
    }

    /// The auth-reliability contract: 403 is a rate limit, never an auth
    /// failure — signing the user out on it is the bug trailhead learned from.
    private static func mapError(_ status: Int, _ data: Data) -> GitHubAPIError {
        switch status {
        case 401: return .unauthorized
        case 403, 429: return .rateLimited
        case 404: return .notFound
        case 409: return .conflict
        default:
            let body = String(bytes: data, encoding: .utf8) ?? ""
            return .http(status, message: body.isEmpty ? nil : body)
        }
    }

    // MARK: - Decoding

    // Kept flat (siblings, not nested types) to stay within SwiftLint's nesting depth.
    private struct OwnerDTO: Decodable { let login: String }

    private struct RepoDTO: Decodable {
        let name: String
        let owner: OwnerDTO
    }

    private struct ContentDTO: Decodable {
        let name: String
        let path: String
        let sha: String
        let type: String
    }

    private struct FileDTO: Decodable {
        let content: String?
        let sha: String
    }

    private struct SHADTO: Decodable { let sha: String }

    private struct CommitContentDTO: Decodable {
        let path: String
        let sha: String
    }

    private struct CommitDTO: Decodable {
        let content: CommitContentDTO
    }

    private func decode<T: Decodable>(_: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubAPIError.invalidResponse("decode \(T.self): \(error)")
        }
    }

    /// Directory listings are arrays; a single file comes back as one object —
    /// wrap it, matching trailhead's getContents.
    private func decodeContents(from data: Data) throws -> [ContentDTO] {
        if let list = try? JSONDecoder().decode([ContentDTO].self, from: data) { return list }
        if let one = try? JSONDecoder().decode(ContentDTO.self, from: data) { return [one] }
        throw GitHubAPIError.invalidResponse("unrecognized contents response")
    }

    private static func decodeBase64UTF8(_ base64: String) -> String? {
        // GitHub wraps base64 at 60 chars with \n; strip them first (trailhead does the same).
        let stripped = base64.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: stripped) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

import Foundation

/// The Cairns GitHub App (reused from the trailhead era: device flow enabled,
/// Contents → Read & Write as its only permission, user-token expiration
/// DISABLED — tokens never expire, there is no refresh flow, by decision).
public enum CairnsGitHubApp {
    // ponytail: paste the real client ID here — it is public information.
    public static let clientID = "REPLACE_WITH_CAIRNS_GITHUB_APP_CLIENT_ID"
}

public struct DeviceCode: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    /// Seconds between polls (GitHub dictates; respect slow_down bumps).
    public let interval: Int
    public let expiresIn: Int

    public init(deviceCode: String, userCode: String, verificationURI: URL, interval: Int, expiresIn: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

public enum DeviceFlowError: Error, Equatable {
    case accessDenied // user hit cancel on github.com
    case expiredToken // code expired before authorization
    case unsupportedResponse(String)
    case http(Int)
}

/// GitHub App device flow, straight against github.com — native apps need no
/// CORS proxy. Requests are form-urlencoded, responses JSON.
public struct GitHubAuth: Sendable {
    public let clientID: String
    let session: URLSession
    /// Injected so tests never actually wait between polls. Defaults to Task.sleep.
    let sleep: @Sendable (TimeInterval) async throws -> Void

    static let deviceCodeURL = URL(string: "https://github.com/login/device/code") ?? URL(fileURLWithPath: "/")
    static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")
        ?? URL(fileURLWithPath: "/")

    public init(clientID: String = CairnsGitHubApp.clientID, session: URLSession = .shared) {
        self.init(clientID: clientID, session: session, sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        })
    }

    init(clientID: String, session: URLSession,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void)
    {
        self.clientID = clientID
        self.session = session
        self.sleep = sleep
    }

    /// POST https://github.com/login/device/code
    public func requestDeviceCode() async throws -> DeviceCode {
        // GitHub Apps take no scope — permissions come from the app config.
        let (data, status) = try await post(Self.deviceCodeURL, form: ["client_id": clientID])
        guard (200 ..< 300).contains(status) else { throw DeviceFlowError.http(status) }
        guard let code = Self.parseDeviceCode(data) else {
            throw DeviceFlowError.unsupportedResponse("malformed device code response")
        }
        return code
    }

    /// Polls POST https://github.com/login/oauth/access_token every
    /// `interval` seconds (honoring slow_down) until authorized, denied, or
    /// expired. Returns the access token.
    public func waitForAuthorization(_ code: DeviceCode) async throws -> String {
        let baseInterval = max(code.interval, 5) // GitHub's floor.
        var interval = TimeInterval(baseInterval)
        // ponytail: bound polls by the code's own lifetime as a safety net —
        // GitHub returns expired_token when the code dies, which is the real
        // terminator. Counter-based (not wall clock) so an injected no-op
        // sleep still terminates. Add a wall-clock deadline if GitHub ever
        // stops sending expired_token.
        let maxPolls = max(1, code.expiresIn / baseInterval)
        for _ in 0 ..< maxPolls {
            switch try await poll(code.deviceCode) {
            case let .success(token): return token
            case .pending: break
            case let .slowDown(newInterval): interval = newInterval ?? (interval + 5)
            }
            try await sleep(interval)
        }
        throw DeviceFlowError.expiredToken
    }

    // MARK: - Polling

    private enum PollResult {
        case success(String)
        case pending
        case slowDown(TimeInterval?)
    }

    private func poll(_ deviceCode: String) async throws -> PollResult {
        let (data, status) = try await post(Self.accessTokenURL, form: [
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        guard (200 ..< 300).contains(status) else { throw DeviceFlowError.http(status) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DeviceFlowError.unsupportedResponse("non-JSON token response")
        }
        return try Self.classify(json)
    }

    private static func classify(_ json: [String: Any]) throws -> PollResult {
        if let token = json["access_token"] as? String { return .success(token) }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown((json["interval"] as? NSNumber)?.doubleValue)
        case "expired_token": throw DeviceFlowError.expiredToken
        case "access_denied": throw DeviceFlowError.accessDenied
        case let other:
            throw DeviceFlowError.unsupportedResponse((json["error_description"] as? String) ?? other ?? "unknown")
        }
    }

    // MARK: - Transport

    private func post(_ url: URL, form: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeForm(form)
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func encodeForm(_ params: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }

    private static func parseDeviceCode(_ data: Data) -> DeviceCode? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uriString = json["verification_uri"] as? String,
              let uri = URL(string: uriString) else { return nil }
        let interval = (json["interval"] as? NSNumber)?.intValue ?? 5
        let expiresIn = (json["expires_in"] as? NSNumber)?.intValue ?? 900
        return DeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURI: uri,
                          interval: interval, expiresIn: expiresIn)
    }
}

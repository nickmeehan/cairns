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

    public init(clientID: String = CairnsGitHubApp.clientID, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    /// POST https://github.com/login/device/code
    public func requestDeviceCode() async throws -> DeviceCode {
        fatalError("unimplemented")
    }

    /// Polls POST https://github.com/login/oauth/access_token every
    /// `interval` seconds (honoring slow_down) until authorized, denied, or
    /// expired. Returns the access token.
    public func waitForAuthorization(_: DeviceCode) async throws -> String {
        fatalError("unimplemented")
    }
}

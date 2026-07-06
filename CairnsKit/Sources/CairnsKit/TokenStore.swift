import Foundation

/// Where the GitHub token lives. Native Keychain storage is the whole reason
/// this rewrite exists — no more PWA storage eviction.
public protocol TokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func clear() throws
}

/// Keychain-backed store (kSecClassGenericPassword, service "app.cairns.github-token").
public struct KeychainTokenStore: TokenStore {
    public init() {}
    public func load() throws -> String? { fatalError("unimplemented") }
    public func save(_: String) throws { fatalError("unimplemented") }
    public func clear() throws { fatalError("unimplemented") }
}

/// Test double.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func load() throws -> String? { lock.withLock { token } }
    public func save(_ token: String) throws { lock.withLock { self.token = token } }
    public func clear() throws { lock.withLock { token = nil } }
}

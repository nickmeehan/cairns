@testable import CairnsKit
import XCTest

/// The KeychainTokenStore can't be unit-tested without touching the real login
/// keychain, so InMemoryTokenStore stands in for the TokenStore seam.
final class TokenStoreTests: XCTestCase {
    func testRoundTripAndClear() throws {
        let store: TokenStore = InMemoryTokenStore()
        XCTAssertNil(try store.load())

        try store.save("ghu_abc")
        XCTAssertEqual(try store.load(), "ghu_abc")

        // save is an upsert — the second write replaces the first.
        try store.save("ghu_def")
        XCTAssertEqual(try store.load(), "ghu_def")

        try store.clear()
        XCTAssertNil(try store.load())
    }
}

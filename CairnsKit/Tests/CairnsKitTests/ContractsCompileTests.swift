import CairnsKit
import XCTest

/// Placeholder keeping the test target non-empty until the real suites land.
final class ContractsCompileTests: XCTestCase {
    func testKitLinks() {
        XCTAssertEqual(GitHubUser(login: "nick").login, "nick")
    }
}

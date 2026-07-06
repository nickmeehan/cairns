@testable import CairnsKit
import XCTest

/// Device-flow state machine, mirroring trailhead's GitHubAuth. Network is
/// stubbed via URLProtocol; the poll delay is an injected no-op so nothing
/// actually waits.
final class GitHubAuthTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string) ?? URL(fileURLWithPath: "/") }

    private func makeAuth(sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in })
        -> GitHubAuth
    {
        GitHubAuth(clientID: "test-client-id", session: StubURLProtocol.makeSession(), sleep: sleep)
    }

    private func deviceCode(interval: Int = 5, expiresIn: Int = 900) -> DeviceCode {
        DeviceCode(deviceCode: "dc_123", userCode: "ABCD-1234",
                   verificationURI: url("https://github.com/login/device"),
                   interval: interval, expiresIn: expiresIn)
    }

    // MARK: requestDeviceCode

    func testRequestDeviceCodeParsesAndPostsForm() async throws {
        StubURLProtocol.box.load([.json(200, [
            "device_code": "dc_123",
            "user_code": "ABCD-1234",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 900,
            "interval": 5,
        ])])

        let code = try await makeAuth().requestDeviceCode()
        XCTAssertEqual(code.deviceCode, "dc_123")
        XCTAssertEqual(code.userCode, "ABCD-1234")
        XCTAssertEqual(code.verificationURI, url("https://github.com/login/device"))
        XCTAssertEqual(code.interval, 5)
        XCTAssertEqual(code.expiresIn, 900)

        let req = try XCTUnwrap(StubURLProtocol.box.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.headers["Accept"], "application/json")
        XCTAssertTrue(req.bodyString.contains("client_id=test-client-id"), req.bodyString)
        // GitHub Apps take no scope.
        XCTAssertFalse(req.bodyString.contains("scope="))
    }

    func testRequestDeviceCodeHTTPErrorMapsToHTTP() async {
        StubURLProtocol.box.load([.text(500, "boom")])
        let error = await thrownError { try await makeAuth().requestDeviceCode() }
        XCTAssertEqual(error as? DeviceFlowError, .http(500))
    }

    func testRequestDeviceCodeMalformedBodyIsUnsupported() async {
        StubURLProtocol.box.load([.text(200, "not json")])
        let error = await thrownError { try await makeAuth().requestDeviceCode() }
        guard case .unsupportedResponse = (error as? DeviceFlowError) else {
            return XCTFail("expected unsupportedResponse, got \(String(describing: error))")
        }
    }

    // MARK: waitForAuthorization

    func testPendingThenSuccessReturnsToken() async throws {
        StubURLProtocol.box.load([
            .json(200, ["error": "authorization_pending"]),
            .json(200, ["access_token": "ghu_final", "token_type": "bearer", "scope": ""]),
        ])
        let token = try await makeAuth().waitForAuthorization(deviceCode())
        XCTAssertEqual(token, "ghu_final")
    }

    func testPollBodyCarriesDeviceCodeClientIdAndGrantType() async throws {
        StubURLProtocol.box.load([.json(200, ["access_token": "ghu_x"])])
        _ = try await makeAuth().waitForAuthorization(deviceCode())
        let body = try XCTUnwrap(StubURLProtocol.box.requests.first).bodyString
        XCTAssertEqual(StubURLProtocol.box.requests.first?.url?.absoluteString,
                       "https://github.com/login/oauth/access_token")
        XCTAssertTrue(body.contains("device_code=dc_123"), body)
        XCTAssertTrue(body.contains("client_id=test-client-id"), body)
        XCTAssertTrue(body.contains("grant_type=urn"), body)
    }

    func testSlowDownBumpsIntervalByFiveWhenFieldAbsent() async throws {
        let recorder = Durations()
        StubURLProtocol.box.load([
            .json(200, ["error": "slow_down"]),
            .json(200, ["access_token": "ghu_slow"]),
        ])
        let token = try await makeAuth(sleep: { recorder.append($0) })
            .waitForAuthorization(deviceCode(interval: 5))
        XCTAssertEqual(token, "ghu_slow")
        // 5s base, +5 after slow_down.
        XCTAssertEqual(recorder.all, [10])
    }

    func testSlowDownHonorsNewIntervalField() async throws {
        let recorder = Durations()
        StubURLProtocol.box.load([
            .json(200, ["error": "slow_down", "interval": 12]),
            .json(200, ["access_token": "ghu_slow"]),
        ])
        _ = try await makeAuth(sleep: { recorder.append($0) })
            .waitForAuthorization(deviceCode(interval: 5))
        XCTAssertEqual(recorder.all, [12])
    }

    func testAccessDeniedThrows() async {
        StubURLProtocol.box.load([.json(200, ["error": "access_denied"])])
        let error = await thrownError { try await makeAuth().waitForAuthorization(deviceCode()) }
        XCTAssertEqual(error as? DeviceFlowError, .accessDenied)
    }

    func testExpiredTokenThrows() async {
        StubURLProtocol.box.load([.json(200, ["error": "expired_token"])])
        let error = await thrownError { try await makeAuth().waitForAuthorization(deviceCode()) }
        XCTAssertEqual(error as? DeviceFlowError, .expiredToken)
    }

    func testUnknownErrorIsUnsupported() async {
        StubURLProtocol.box.load([.json(200, [
            "error": "something_new", "error_description": "A detailed message",
        ])])
        let error = await thrownError { try await makeAuth().waitForAuthorization(deviceCode()) }
        XCTAssertEqual(error as? DeviceFlowError, .unsupportedResponse("A detailed message"))
    }

    func testExhaustingPollsThrowsExpired() async {
        // expiresIn 10 / interval 5 = 2 polls, both pending → expiredToken.
        StubURLProtocol.box.load([
            .json(200, ["error": "authorization_pending"]),
            .json(200, ["error": "authorization_pending"]),
        ])
        let error = await thrownError {
            try await makeAuth().waitForAuthorization(deviceCode(interval: 5, expiresIn: 10))
        }
        XCTAssertEqual(error as? DeviceFlowError, .expiredToken)
    }
}

/// Thread-safe recorder for injected sleep durations.
final class Durations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func append(_ duration: TimeInterval) { lock.withLock { values.append(duration) } }
    var all: [TimeInterval] { lock.withLock { values } }
}

/// Runs `operation`, expecting it to throw, and returns the error for the
/// caller to assert on. A single (trailing) closure keeps SwiftLint's
/// multiple-closures rule happy; the explicit closure body keeps its `await`.
func thrownError(_ operation: () async throws -> some Any,
                 file: StaticString = #filePath, line: UInt = #line) async -> Error?
{
    do {
        _ = try await operation()
        XCTFail("expected an error to be thrown", file: file, line: line)
        return nil
    } catch {
        return error
    }
}

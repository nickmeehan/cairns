import Foundation

/// One canned response for a stubbed request. Either an HTTP reply or a
/// transport-level URLError (to exercise `.network` mapping).
struct Stub {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = .init()
    var error: URLError?

    static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> Stub {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return Stub(status: status, headers: headers, body: data)
    }

    static func text(_ status: Int, _ string: String) -> Stub {
        Stub(status: status, body: Data(string.utf8))
    }

    static func failure(_ code: URLError.Code) -> Stub {
        Stub(error: URLError(code))
    }
}

/// What actually hit the wire — captured for request assertions.
struct RecordedRequest {
    let url: URL?
    let method: String
    let headers: [String: String]
    let body: Data

    var bodyString: String { String(bytes: body, encoding: .utf8) ?? "" }
    var bodyJSON: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

/// Thread-safe FIFO of stubs + recorded requests. URLProtocol callbacks run
/// off the test thread, so all shared state lives behind a lock.
final class StubBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [Stub] = []
    private var recorded: [RecordedRequest] = []

    func load(_ stubs: [Stub]) { lock.withLock { self.stubs = stubs; recorded = [] } }
    func next() -> Stub? { lock.withLock { stubs.isEmpty ? nil : stubs.removeFirst() } }
    func append(_ request: RecordedRequest) { lock.withLock { recorded.append(request) } }
    var requests: [RecordedRequest] { lock.withLock { recorded } }
}

/// URLProtocol that serves queued `Stub`s in order and records every request.
/// Install via `StubURLProtocol.makeSession()`. Non-final: URLProtocol requires
/// overriding `class func`s, which can't be expressed as `static`.
class StubURLProtocol: URLProtocol {
    static let box = StubBox()

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.box.append(RecordedRequest(
            url: request.url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(request)
        ))

        guard let stub = Self.box.next() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status,
                                             httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession moves `httpBody` into `httpBodyStream` for uploads, so read
    /// whichever is populated.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

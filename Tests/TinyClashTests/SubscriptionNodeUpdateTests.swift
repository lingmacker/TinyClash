import Foundation
import XCTest
@testable import TinyClash

/// All HTTP requests are intercepted; no real core, subscription, or YAML is touched.
@MainActor
final class SubscriptionNodeUpdateTests: XCTestCase {
    private func api(providers: String, updates: [String: (Int, String)] = [:], listStatus: Int = 200) -> MihomoAPI {
        var responses = updates
        responses["GET /providers/proxies"] = (listStatus, providers)
        ProviderUpdateURLProtocol.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderUpdateURLProtocol.self]
        return MihomoAPI(host: "unit.test", port: 80, secret: "test", sessionConfiguration: configuration)
    }

    func testOnlyHTTPNodeSubscriptionsAreUpdated() async throws {
        let api = api(providers: """
        {"providers":{
          "Remote":{"name":"Remote","type":"Proxy","vehicleType":"HTTP"},
          "Local":{"name":"Local","type":"Proxy","vehicleType":"File"},
          "Inline":{"name":"Inline","type":"Proxy","vehicleType":"Inline"},
          "Compatible":{"name":"Compatible","type":"Proxy","vehicleType":"Compatible"}
        }}
        """, updates: ["PUT /providers/proxies/Remote": (204, "")])
        defer { api.session.invalidateAndCancel() }
        let failed = try await api.updateSubscriptionNodes()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(ProviderUpdateURLProtocol.requests, ["GET /providers/proxies", "PUT /providers/proxies/Remote"])
    }

    func testIndividualFailureDoesNotPreventRemainingSubscriptionsUpdating() async throws {
        let api = api(providers: """
        {"providers":{
          "A":{"name":"A","type":"Proxy","vehicleType":"HTTP"},
          "B":{"name":"B","type":"Proxy","vehicleType":"Http"}
        }}
        """, updates: ["PUT /providers/proxies/A": (503, "{\"message\":\"offline\"}"),
                       "PUT /providers/proxies/B": (204, "")])
        defer { api.session.invalidateAndCancel() }
        let failed = try await api.updateSubscriptionNodes()
        XCTAssertEqual(failed, ["A"])
        XCTAssertEqual(ProviderUpdateURLProtocol.requests,
                       ["GET /providers/proxies", "PUT /providers/proxies/A", "PUT /providers/proxies/B"])
    }

    func testProviderEnumerationFailureIsNotReportedAsSuccess() async throws {
        let api = api(providers: "{\"message\":\"unavailable\"}", listStatus: 503)
        defer { api.session.invalidateAndCancel() }
        do {
            _ = try await api.updateSubscriptionNodes()
            XCTFail("Expected enumeration failure")
        } catch APIError.http(let code, _) {
            XCTAssertEqual(code, 503)
        }
        XCTAssertEqual(ProviderUpdateURLProtocol.requests, ["GET /providers/proxies"])
    }

    func testMissingHTTPSubscriptionsAreReportedWithoutUpdatingLocalProviders() async throws {
        for providers in ["{\"providers\":{}}", """
        {"providers":{"Local":{"name":"Local","type":"Proxy","vehicleType":"File"}}}
        """] {
            let api = api(providers: providers)
            defer { api.session.invalidateAndCancel() }
            do {
                _ = try await api.updateSubscriptionNodes()
                XCTFail("Expected no-node-subscriptions error")
            } catch APIError.noNodeSubscriptions {
                XCTAssertEqual(ProviderUpdateURLProtocol.requests, ["GET /providers/proxies"])
            }
        }
    }

    func testSubscriptionNamesAreEscapedAsOnePathComponent() async throws {
        let path = "PUT /providers/proxies/%E8%AE%A2%E9%98%85%20A%2FB"
        let api = api(providers: """
        {"providers":{"Remote":{"name":"订阅 A/B","type":"Proxy","vehicleType":"HTTP"}}}
        """, updates: [path: (204, "")])
        defer { api.session.invalidateAndCancel() }
        let failed = try await api.updateSubscriptionNodes()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(ProviderUpdateURLProtocol.requests, ["GET /providers/proxies", path])
    }

    func testCancelledUpdateDoesNotSendRequests() async throws {
        let api = api(providers: "{\"providers\":{}}")
        defer { api.session.invalidateAndCancel() }
        let task = Task { try await api.updateSubscriptionNodes() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(ProviderUpdateURLProtocol.requests.isEmpty)
        }
    }
}

private final class ProviderUpdateURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responses: [String: (Int, String)] = [:]
    private static var recorded: [String] = []

    static var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset(_ responses: [String: (Int, String)]) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath
        let key = "\(request.httpMethod ?? "GET") \(path)"
        Self.lock.lock()
        Self.recorded.append(key)
        let stub = Self.responses[key] ?? (500, "Unexpected test request: \(key)")
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: stub.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

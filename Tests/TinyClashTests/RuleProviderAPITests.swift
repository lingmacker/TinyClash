import Foundation
import XCTest
@testable import TinyClash

@MainActor
final class RuleProviderAPITests: XCTestCase {
    private func api(_ responses: [String: (Int, String)]) -> MihomoAPI {
        RuleProviderURLProtocol.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuleProviderURLProtocol.self]
        return MihomoAPI(host: "unit.test", port: 80, secret: "test", sessionConfiguration: configuration)
    }

    func testRuleProviderMetadataAndRemoteEligibility() async throws {
        let api = api(["GET /providers/rules": (200, """
        {"providers":{
          "B":{"name":"B","type":"Rule","vehicleType":"File","behavior":"classical","ruleCount":3},
          "A":{"name":"A","type":"Rule","vehicleType":"HTTP","behavior":"domain","ruleCount":42,"updatedAt":"2026-11-14T12:00:00Z"},
          "C":{"name":"C","type":"Rule","vehicleType":"Inline","ruleCount":0},
          "D":{"name":"D","type":"Rule","vehicleType":"Http"}
        }}
        """)])
        defer { api.session.invalidateAndCancel() }
        let providers = try await api.ruleProviders()
        XCTAssertEqual(providers.map(\.name), ["A", "B", "C", "D"])
        XCTAssertEqual(providers.filter(\.isRemoteRuleProvider).map(\.name), ["A", "D"])
        XCTAssertEqual(providers[0].ruleCount, 42)
        XCTAssertEqual(providers[0].behavior, "domain")
        XCTAssertEqual(providers[0].updatedAt, "2026-11-14T12:00:00Z")
        XCTAssertNil(providers[3].ruleCount)
        XCTAssertEqual(RuleProviderURLProtocol.requests, ["GET /providers/rules"])
    }

    func testUpdateEscapesNameAndOnlyTouchesRuleProviderEndpoint() async throws {
        let path = "PUT /providers/rules/%E8%A7%84%E5%88%99%20A%2FB"
        let api = api([path: (204, "")])
        defer { api.session.invalidateAndCancel() }
        try await api.updateRuleProvider("规则 A/B")
        XCTAssertEqual(RuleProviderURLProtocol.requests, [path])
    }

    func testListingFailureIsNotAnEmptySuccess() async throws {
        let api = api(["GET /providers/rules": (503, "{\"message\":\"unavailable\"}")])
        defer { api.session.invalidateAndCancel() }
        do {
            _ = try await api.ruleProviders()
            XCTFail("Expected enumeration error")
        } catch APIError.http(let code, let message) {
            XCTAssertEqual(code, 503)
            XCTAssertEqual(message, "unavailable")
        }
    }

    func testUpdateFailureIncludesCoreMessage() async throws {
        let api = api(["PUT /providers/rules/Remote": (502, "{\"message\":\"download failed\"}")])
        defer { api.session.invalidateAndCancel() }
        do {
            try await api.updateRuleProvider("Remote")
            XCTFail("Expected update error")
        } catch APIError.http(let code, let message) {
            XCTAssertEqual(code, 502)
            XCTAssertEqual(message, "download failed")
        }
    }

    func testMalformedResponseIsNotAnEmptySuccess() async throws {
        let api = api(["GET /providers/rules": (200, "{\"providers\":{\"bad\":{\"name\":\"bad\"}}}")])
        defer { api.session.invalidateAndCancel() }
        do {
            _ = try await api.ruleProviders()
            XCTFail("Expected decoding error")
        } catch is DecodingError {}
    }
}

private final class RuleProviderURLProtocol: URLProtocol, @unchecked Sendable {
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

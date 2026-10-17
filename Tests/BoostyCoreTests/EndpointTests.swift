import XCTest
@testable import BoostyCore

final class EndpointTests: XCTestCase {
    func testNormalizesHTTPSBasePath() throws {
        let endpoint = try BrokerEndpoint("https://broker.example:8443/tv/broker///")
        XCTAssertEqual(endpoint.url.absoluteString, "https://broker.example:8443/tv/broker")
        XCTAssertEqual(try BrokerEndpoint("https://broker.example/").url.absoluteString, "https://broker.example")
    }

    func testRejectsUnsafeOrMalformedEndpoints() {
        for input in ["http://example.com", "https:///api", "https://user:pass@example.com", "https://example.com?", "https://example.com#", "https://example.com/a/../b", "https://example.com/%2e%2e/x", "https://example.com/%252e%252e/x", "https://example.com/a%2fb", "https://example.com/%", " https://example.com", "https://exam ple.com", "https://example.com/\\evil"] {
            XCTAssertThrowsError(try BrokerEndpoint(input), input)
        }
    }
}

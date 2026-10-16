import Foundation
import Testing
@testable import SwiftMCP

/// Tests when the legacy endpoint URL honors forwarded headers.
@Suite("Forwarded headers")
struct ForwardedHeaderTests {
    /// The session ID every test announces.
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Returns a GET /sse request that carries a Host header and spoofed forwarded headers.
    private func makeRequest() -> HTTPRouteRequest<Data?> {
        HTTPRouteRequest<Data?>(
            method: .GET, uri: "/sse", path: "/sse",
            headers: [
                ("Host", "mcp.example.com"),
                ("X-Forwarded-Proto", "https"),
                ("X-Forwarded-Port", "8443"),
            ],
            body: nil,
            pathParams: [:], queryParams: []
        )
    }

    /// Checks that the endpoint event ignores forwarded headers by default.
    @Test func endpointIgnoresForwardedHeadersByDefault() {
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 8080)
        let url = transport.endpointUrl(from: makeRequest(), sessionID: sessionID)
        #expect(url?.absoluteString == "http://mcp.example.com:8080/messages/\(sessionID.uuidString)")
    }

    /// Checks that the endpoint event honors forwarded headers when the transport trusts them.
    @Test func endpointHonorsForwardedHeadersWhenTrusted() {
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 8080)
        transport.trustsForwardedHeaders = true
        let url = transport.endpointUrl(from: makeRequest(), sessionID: sessionID)
        #expect(url?.absoluteString == "https://mcp.example.com:8443/messages/\(sessionID.uuidString)")
    }
}

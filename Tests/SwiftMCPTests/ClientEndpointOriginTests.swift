import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SwiftMCP

/// Tests that the SSE client posts only to endpoints on its own origin.
@Suite("Client endpoint origin")
struct ClientEndpointOriginTests {
    /// Checks that the connect fails when the server announces an endpoint on another origin.
    @Test func foreignEndpointFailsTheConnect() async throws {
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.trustsForwardedHeaders = true
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        let url = try #require(URL(string: "http://127.0.0.1:\(transport.port)/sse"))
        let config = MCPServerSseConfig(url: url, headers: ["X-Forwarded-Proto": "https"])
        let proxy = MCPServerProxy(config: .sse(config: config))
        defer { Task { await proxy.disconnect() } }

        do {
            try await proxy.connect()
            Issue.record("The connect succeeded with an endpoint on another origin.")
        } catch {
            #expect(String(describing: error).contains("another origin"))
        }
        #expect(await proxy.endpointURL == nil)
    }

    /// Checks that origins match on scheme, host, and port, with letter case and default ports ignored.
    @Test func originComparison() throws {
        func sameOrigin(_ first: String, _ second: String) throws -> Bool {
            try #require(URL(string: first)).hasSameOrigin(as: try #require(URL(string: second)))
        }
        #expect(try sameOrigin("http://127.0.0.1:8080/messages/1", "http://127.0.0.1:8080/sse"))
        #expect(try sameOrigin("HTTP://LOCALHOST/a", "http://localhost:80/b"))
        #expect(try sameOrigin("https://h/a", "https://h:443/b"))
        #expect(try !sameOrigin("https://127.0.0.1:8080/a", "http://127.0.0.1:8080/b"))
        #expect(try !sameOrigin("http://127.0.0.2:8080/a", "http://127.0.0.1:8080/b"))
        #expect(try !sameOrigin("http://127.0.0.1:9090/a", "http://127.0.0.1:8080/b"))
        #expect(try !sameOrigin("file:///a", "file:///b"))
    }

    /// Checks that a redirect is allowed only when it stays on the request's origin.
    @Test func redirectsStayOnTheOrigin() throws {
        let original = try #require(URL(string: "http://127.0.0.1:8080/messages/1"))
        #expect(SameOriginRedirectDelegate.allowsRedirect(from: original, to: URL(string: "http://127.0.0.1:8080/messages/2")))
        #expect(!SameOriginRedirectDelegate.allowsRedirect(from: original, to: URL(string: "http://elsewhere.example/messages/1")))
        #expect(!SameOriginRedirectDelegate.allowsRedirect(from: original, to: URL(string: "https://127.0.0.1:8080/messages/1")))
        #expect(!SameOriginRedirectDelegate.allowsRedirect(from: nil, to: original))
    }

    /// Checks that a same-origin session follows a redirect on its origin and delivers one to another origin unfollowed.
    @Test func sessionFollowsOnlySameOriginRedirects() async throws {
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.addRoute(.POST, "/away") { _ in
            HTTPRouteResponse<Data?>(status: .found, headers: [("Location", "http://127.0.0.1:1/away")], body: nil)
        }
        transport.addRoute(.POST, "/here") { _ in
            HTTPRouteResponse<Data?>(status: .found, headers: [("Location", "/landed")], body: nil)
        }
        transport.addRoute(.GET, "/landed") { _ in
            HTTPRouteResponse<Data?>(status: .ok, body: Data("landed".utf8))
        }
        try await transport.start()
        defer { Task { try? await transport.stop() } }
        let base = "http://127.0.0.1:\(transport.port)"
        let session = URLSession.sameOrigin()
        defer { session.finishTasksAndInvalidate() }

        var away = URLRequest(url: try #require(URL(string: "\(base)/away")))
        away.httpMethod = "POST"
        let (_, awayResponse) = try await session.data(for: away)
        #expect((awayResponse as? HTTPURLResponse)?.statusCode == 302)

        var here = URLRequest(url: try #require(URL(string: "\(base)/here")))
        here.httpMethod = "POST"
        let (hereData, hereResponse) = try await session.data(for: here)
        #expect((hereResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: hereData, as: UTF8.self) == "landed")
    }
}

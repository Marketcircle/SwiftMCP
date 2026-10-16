import Foundation
import Testing
@testable import SwiftMCP

/// Tests how logged payloads and headers are trimmed and masked.
@Suite("Log redaction")
struct LogRedactionTests {
    /// Checks that a short payload is logged unchanged.
    @Test func shortPayloadStaysWhole() {
        let payload = String(repeating: "a", count: String.loggedPayloadLimit)
        #expect(payload.truncatedForLog == payload)
    }

    /// Checks that a long payload is cut to the limit and reports how much was left out.
    @Test func longPayloadIsCut() {
        let payload = String(repeating: "a", count: String.loggedPayloadLimit + 50)
        let logged = payload.truncatedForLog
        #expect(logged.hasPrefix(String(repeating: "a", count: String.loggedPayloadLimit) + "…"))
        #expect(logged.hasSuffix("(50 more characters)"))
    }

    /// Checks that credential headers are masked in any letter case and other headers are kept.
    @Test func credentialHeadersAreMasked() {
        let lines = HTTPLogger.headerLines([
            (name: "Authorization", value: "Bearer secret"),
            (name: "cookie", value: "session=secret"),
            (name: "Accept", value: "text/event-stream"),
        ])
        #expect(!lines.contains("secret"))
        #expect(lines.contains("Authorization: <redacted>\n"))
        #expect(lines.contains("cookie: <redacted>\n"))
        #expect(lines.contains("Accept: text/event-stream\n"))
    }

    /// Checks that OAuth routes never log their bodies and MCP routes may.
    @Test func oauthBodiesAreNeverLogged() {
        #expect(!HTTPLogger.showsBodies(for: "/oauth/token"))
        #expect(!HTTPLogger.showsBodies(for: "/u/login?state=abc"))
        #expect(!HTTPLogger.showsBodies(for: "/authorize?client_id=x"))
        #expect(HTTPLogger.showsBodies(for: "/mcp"))
        #expect(HTTPLogger.showsBodies(for: "/messages/123"))
    }
}

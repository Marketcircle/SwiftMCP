import Foundation
import Testing
@testable import SwiftMCP

/// Tests how a session's token is checked when the transport has no OAuth configuration.
@Suite("Token binding without OAuth")
struct TokenBindingTests {
    /// Returns a transport whose handler accepts only the token "good".
    private func makeTransport() -> HTTPSSETransport {
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.authorizationHandler = { $0 == "good" ? .authorized : .unauthorized("Bad token") }
        return transport
    }

    /// Checks that a handler token gets no expiry and keeps working past the default lifetime.
    @Test func handlerTokenDoesNotExpire() async throws {
        let transport = makeTransport()
        let id = UUID()
        #expect(await transport.authorize("good", sessionID: id).isAuthorized)

        let session = try #require(await transport.sessionManager.existingSession(id: id))
        #expect(await session.accessTokenExpiry == nil)

        await session.setAccessTokenExpiry(.distantPast)
        #expect(await transport.authorize("good", sessionID: id).isAuthorized)
    }

    /// Checks that a bound token stops working once the handler rejects it.
    @Test func handlerDecidesEveryRequest() async {
        let transport = makeTransport()
        let id = UUID()
        #expect(await transport.authorize("good", sessionID: id).isAuthorized)

        transport.authorizationHandler = { _ in .unauthorized("Rotated") }
        #expect(await !transport.authorize("good", sessionID: id).isAuthorized)
    }

    /// Checks that the constant-time compare matches only identical strings.
    @Test func constantTimeCompare() {
        #expect("token".constantTimeEquals("token"))
        #expect(!"token".constantTimeEquals("tokem"))
        #expect(!"token".constantTimeEquals("token2"))
        #expect("".constantTimeEquals(""))
    }
}

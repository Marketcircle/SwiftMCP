import Foundation
import Testing
@testable import SwiftMCP

/// Tests how idle sessions are found and removed.
@Suite("Session idle expiry")
struct SessionIdleTests {
    /// Checks that a session without a channel stays until it has been idle past the timeout.
    @Test func idleSessionWithoutChannelIsRemoved() async {
        let manager = SessionManager()
        let id = UUID()
        _ = await manager.session(id: id)

        await manager.removeIdleSessions(olderThan: 60)
        #expect(await manager.existingSession(id: id) != nil)

        await manager.removeIdleSessions(olderThan: -1)
        #expect(await manager.existingSession(id: id) == nil)
    }

    /// Checks that a request on a session moves its last activity forward.
    @Test func requestMarksSessionActive() async throws {
        let manager = SessionManager()
        let id = UUID()
        let session = await manager.session(id: id)
        let first = await session.lastActivity

        try await Task.sleep(nanoseconds: 10_000_000)
        _ = await manager.session(id: id)
        #expect(await session.lastActivity > first)
    }
}

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

    /// Checks that the ping keep-alive skips a session without an open stream.
    @Test func pingSkipsSessionsWithoutStream() async throws {
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.keepAliveMode = .ping
        let session = await transport.sessionManager.session(id: UUID())

        transport.sendKeepAlive()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await session.responseTasks.isEmpty)
    }

    /// Checks that idle sessions are still swept after keep-alive messages are turned off.
    @Test func idleSweepRunsWithoutKeepAlive() async throws {
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.sessionIdleTimeout = 0.1
        transport.sessionSweepInterval = 0.05
        try await transport.start()
        defer { Task { try? await transport.stop() } }
        transport.keepAliveMode = .none

        let id = UUID()
        _ = await transport.sessionManager.session(id: id)
        let deadline = Date().addingTimeInterval(3)
        while await transport.sessionManager.existingSession(id: id) != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await transport.sessionManager.existingSession(id: id) == nil)
    }
}

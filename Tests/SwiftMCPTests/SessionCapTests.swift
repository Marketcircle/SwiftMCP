import Foundation
import Testing
@testable import SwiftMCP

/// Tests how the session manager holds its cap when sessions are created at once.
@Suite("Session cap")
struct SessionCapTests {
    /// Checks that creations racing for the last slots never pass the limit.
    @Test func concurrentCreationHoldsTheLimit() async {
        let manager = SessionManager()
        let created = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<40 {
                group.addTask { await manager.session(id: UUID(), limit: 5) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(created == 5)
        #expect(await manager.sessions.count == 5)
    }

    /// Checks that an existing session comes back whatever the limit, and a new one past it does not.
    @Test func existingSessionIgnoresTheLimit() async {
        let manager = SessionManager()
        let id = UUID()
        _ = await manager.session(id: id, limit: 1)
        #expect(await manager.session(id: id, limit: 0) != nil)
        #expect(await manager.session(id: UUID(), limit: 1) == nil)
    }
}

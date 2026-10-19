import Foundation
import Testing
@testable import SwiftMCP

/// Tests the session cap under concurrent creation.
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

    /// Checks that the limit applies only to new sessions.
    @Test func existingSessionIgnoresTheLimit() async {
        let manager = SessionManager()
        let id = UUID()
        _ = await manager.session(id: id, limit: 1)
        #expect(await manager.session(id: id, limit: 0) != nil)
        #expect(await manager.session(id: UUID(), limit: 1) == nil)
    }
}

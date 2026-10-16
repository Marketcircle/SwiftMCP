import Foundation
import Testing
@testable import SwiftMCP

/// Tests how the HTTP transport caps open connections.
@Suite("Connection limit", .serialized)
struct ConnectionLimitTests {
    /// Opens a raw socket to the port and returns its descriptor.
    private func connectSocket(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return fd
    }

    /// Sends a request for an unknown path and returns how many bytes of answer arrive within a second.
    private func answerLength(on fd: Int32) -> Int {
        let request = "GET /nothing-here HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        return max(recv(fd, &buffer, buffer.count, 0), 0)
    }

    /// Checks that a connection past the cap closes without an answer, and that a freed slot takes a new one.
    @Test func connectionPastTheCapIsClosed() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.maxConnections = 2
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        let first = connectSocket(port: transport.port)
        let second = connectSocket(port: transport.port)
        defer { close(second) }
        #expect(answerLength(on: first) > 0)
        #expect(answerLength(on: second) > 0)

        let third = connectSocket(port: transport.port)
        #expect(answerLength(on: third) == 0)
        close(third)

        close(first)
        try await Task.sleep(for: .milliseconds(200))
        let fourth = connectSocket(port: transport.port)
        defer { close(fourth) }
        #expect(answerLength(on: fourth) > 0)
        #endif
    }
}

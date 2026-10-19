import Foundation
import Testing
@testable import SwiftMCP

/// Tests how the HTTP transport caps open connections.
@Suite("Connection limit", .serialized)
struct ConnectionLimitTests {
    #if canImport(Darwin)
    /// Opens a raw socket to the port and returns its descriptor.
    private func connectSocket(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return fd
    }

    /// Sends a request for an unknown path and returns what `recv` gives back: answer bytes, 0 once the server closes, or -1 after a one-second wait.
    private func answerLength(on fd: Int32) -> Int {
        let request = "GET /nothing-here HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count < 0 && errno == ECONNRESET ? 0 : count
    }
    #endif

    /// Checks that a new connection at the cap closes the longest-idle connection and is answered.
    @Test func idleConnectionMakesRoom() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.maxConnections = 2
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        let first = connectSocket(port: transport.port)
        defer { close(first) }
        #expect(answerLength(on: first) > 0)
        try await Task.sleep(for: .milliseconds(50))
        let second = connectSocket(port: transport.port)
        defer { close(second) }
        #expect(answerLength(on: second) > 0)

        let third = connectSocket(port: transport.port)
        defer { close(third) }
        #expect(answerLength(on: third) > 0)

        var buffer = [UInt8](repeating: 0, count: 64)
        #expect(recv(first, &buffer, buffer.count, 0) <= 0)
        #expect(answerLength(on: second) > 0)
        #endif
    }

    /// Checks that a new connection at the cap is refused when every connection has a request in progress.
    @Test func busyConnectionsAreNotEvicted() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.maxConnections = 2
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAccept: application/json\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n"
        let first = connectSocket(port: transport.port)
        defer { close(first) }
        let second = connectSocket(port: transport.port)
        defer { close(second) }
        for fd in [first, second] {
            _ = head.withCString { send(fd, $0, strlen($0), 0) }
        }
        try await Task.sleep(for: .milliseconds(100))

        let third = connectSocket(port: transport.port)
        defer { close(third) }
        #expect(answerLength(on: third) == 0)

        _ = "0\r\n\r\n".withCString { send(first, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        #expect(recv(first, &buffer, buffer.count, 0) > 0)
        #endif
    }
}

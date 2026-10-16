import Foundation
import Testing
@testable import SwiftMCP

/// Tests how the HTTP transport times out requests that go quiet or run too long.
@Suite("Request timeouts", .serialized)
struct RequestTimeoutTests {
    /// Returns a started transport with short timeouts.
    private func startTransport() async throws -> HTTPSSETransport {
        let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
        transport.requestReadTimeout = 0.3
        transport.requestBodyDeadline = 0.6
        try await transport.start()
        return transport
    }

    #if canImport(Darwin)
    /// Opens a raw socket to the port with a one-second receive timeout and no SIGPIPE.
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
    #endif

    /// Checks that a connection that never sends a request head is closed.
    @Test func silentConnectionTimesOut() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = try await startTransport()
        defer { Task { try? await transport.stop() } }

        let fd = connectSocket(port: transport.port)
        defer { close(fd) }
        let start = Date()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(fd, &buffer, buffer.count, 0)
        #expect(Date().timeIntervalSince(start) < 0.9)
        #expect(count == 0)
        #endif
    }

    /// Checks that a body that keeps dripping bytes still ends with a 408 at the body deadline.
    @Test func slowDripBodyHitsTheDeadline() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = try await startTransport()
        defer { Task { try? await transport.stop() } }

        let fd = connectSocket(port: transport.port)
        defer { close(fd) }
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        _ = head.withCString { send(fd, $0, strlen($0), 0) }

        var answer = ""
        var buffer = [UInt8](repeating: 0, count: 1024)
        let start = Date()
        while Date().timeIntervalSince(start) < 1.5 {
            let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
            if count > 0 {
                answer = String(decoding: buffer[0..<count], as: UTF8.self)
                break
            }
            if count == 0 { break }
            _ = "1\r\n{\r\n".withCString { send(fd, $0, strlen($0), 0) }
            usleep(100_000)
        }
        #expect(answer.hasPrefix("HTTP/1.1 408"))
        #expect(Date().timeIntervalSince(start) < 1.2)
        #endif
    }
}

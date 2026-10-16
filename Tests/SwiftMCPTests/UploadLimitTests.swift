import Foundation
import Testing
@testable import SwiftMCP

/// A server that takes uploads of at most 16 bytes.
@MCPServer
final class SmallUploadServer: MCPFileUploadHandling {
    /// The most bytes one upload may hold.
    var maxUploadSize: Int { 16 }
}

/// Tests the upload route's limits on size and sessions.
@Suite("Upload limits")
struct UploadLimitTests {
    /// Returns the names of the upload temp files the route writes.
    private func uploadTempFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("mcp-upload-") && !$0.hasPrefix("mcp-upload-test-") })
    }

    /// Sends the raw request to the port and returns once the server answers or one second passes.
    private func sendRaw(_ request: String, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        _ = recv(fd, &buffer, buffer.count, 0)
    }

    /// Checks that an oversized chunked upload fails the waiting CID and leaves no temp file.
    @Test func oversizedUploadFailsTheCID() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = HTTPSSETransport(server: SmallUploadServer(), host: "127.0.0.1", port: 0)
        try await transport.start()
        defer { Task { try? await transport.stop() } }
        let filesBefore = uploadTempFiles()

        let store = transport.pendingUploadStore
        let waiter = Task { () -> Error? in
            do {
                _ = try await store.waitForUpload(cid: "big", progressToken: nil, sessionID: UUID())
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        let body = String(repeating: "x", count: 64)
        sendRaw("POST /mcp/uploads/big HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n40\r\n\(body)\r\n0\r\n\r\n", port: transport.port)

        let deadline = Date().addingTimeInterval(3)
        while await store.isExpectedOrArrived(cid: "big"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(await !store.isExpectedOrArrived(cid: "big"), "The CID is still waiting.")
        #expect(await waiter.value is UploadTooLargeError)
        #expect(uploadTempFiles() == filesBefore)
        #endif
    }

    /// Checks that an upload whose Content-Length passes the limit fails the waiting CID.
    @Test func oversizedContentLengthFailsTheCID() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = HTTPSSETransport(server: SmallUploadServer(), host: "127.0.0.1", port: 0)
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        let store = transport.pendingUploadStore
        let waiter = Task { () -> Error? in
            do {
                _ = try await store.waitForUpload(cid: "declared", progressToken: nil, sessionID: UUID())
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        sendRaw("POST /mcp/uploads/declared HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 64\r\n\r\n", port: transport.port)

        let deadline = Date().addingTimeInterval(3)
        while await store.isExpectedOrArrived(cid: "declared"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(await !store.isExpectedOrArrived(cid: "declared"), "The CID is still waiting.")
        #expect(await waiter.value is UploadTooLargeError)
        #endif
    }

    /// Checks that an upload without a session header creates no session.
    @Test func uploadWithoutSessionCreatesNone() async throws {
        let transport = HTTPSSETransport(server: SmallUploadServer(), host: "127.0.0.1", port: 0)
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(transport.port)/mcp/uploads/small")))
        request.httpMethod = "POST"
        request.httpBody = Data("tiny".utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(await transport.sessionManager.sessions.isEmpty)
        await transport.pendingUploadStore.expireEarlyArrivals(olderThan: -1)
    }

    /// Checks that an upload naming an unknown or malformed session gets 404.
    @Test func uploadForUnknownSessionIsRejected() async throws {
        let transport = HTTPSSETransport(server: SmallUploadServer(), host: "127.0.0.1", port: 0)
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(transport.port)/mcp/uploads/small")))
        request.httpMethod = "POST"
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Mcp-Session-Id")
        request.httpBody = Data("tiny".utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)

        request.setValue("not-a-session", forHTTPHeaderField: "Mcp-Session-Id")
        let (_, malformed) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((malformed as? HTTPURLResponse)?.statusCode == 404)
        #expect(await transport.sessionManager.sessions.isEmpty)
    }
}

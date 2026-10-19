import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SwiftMCP

/// A server that takes uploads of at most 16 bytes.
@MCPServer
final class SmallUploadServer: MCPFileUploadHandling {
    /// The most bytes one upload may hold.
    var maxUploadSize: Int { 16 }
}

/// Tests the upload route's limits on size and sessions.
@Suite("Upload limits", .serialized)
struct UploadLimitTests {
    /// Returns the names of the upload temp files the route writes.
    private func uploadTempFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("mcp-upload-") && !$0.hasPrefix("mcp-upload-test-") })
    }

    #if canImport(Darwin)
    /// Sends the raw request to the port and returns the first answer bytes, or an empty string after one second.
    @discardableResult
    private func sendRaw(_ request: String, port: Int) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
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
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
    }
    #endif

    /// Waits up to three seconds until the store expects the given CID.
    private func waitUntilExpected(_ cid: String, in store: PendingUploadStore) async throws {
        let deadline = Date().addingTimeInterval(3)
        while await !store.isExpectedOrArrived(cid: cid), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
        try await waitUntilExpected("big", in: store)

        let body = String(repeating: "x", count: 64)
        sendRaw("POST /mcp/uploads/big HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n40\r\n\(body)\r\n0\r\n\r\n", port: transport.port)

        let deadline = Date().addingTimeInterval(3)
        while await store.isExpectedOrArrived(cid: "big"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(await !store.isExpectedOrArrived(cid: "big"), "The CID is still waiting.")
        #expect(await waiter.value is UploadTooLargeError)
        #expect(uploadTempFiles().subtracting(filesBefore).isEmpty)
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
        try await waitUntilExpected("declared", in: store)

        sendRaw("POST /mcp/uploads/declared HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 64\r\n\r\n", port: transport.port)

        let deadline = Date().addingTimeInterval(3)
        while await store.isExpectedOrArrived(cid: "declared"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(await !store.isExpectedOrArrived(cid: "declared"), "The CID is still waiting.")
        #expect(await waiter.value is UploadTooLargeError)
        #endif
    }

    /// Checks that an upload rejected by its Content-Length gets exactly one response before the socket closes.
    @Test func rejectedUploadGetsOneResponse() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = HTTPSSETransport(server: SmallUploadServer(), host: "127.0.0.1", port: 0)
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(transport.port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let request = "POST /mcp/uploads/huge HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 99999999\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }

        var answer = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            answer += String(decoding: buffer[0..<count], as: UTF8.self)
        }
        #expect(answer.hasPrefix("HTTP/1.1 413"))
        #expect(answer.components(separatedBy: "HTTP/1.1 ").count == 2)
        #endif
    }

    /// Checks that a client that disconnects mid-body fails the waiting CID and leaves no temp file.
    @Test func disconnectMidBodyFailsTheCID() async throws {
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
                _ = try await store.waitForUpload(cid: "partial", progressToken: nil, sessionID: UUID())
                return nil
            } catch {
                return error
            }
        }
        try await waitUntilExpected("partial", in: store)

        // The socket sends one chunk and closes without the last chunk.
        sendRaw("POST /mcp/uploads/partial HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n", port: transport.port)

        let deadline = Date().addingTimeInterval(3)
        while await store.isExpectedOrArrived(cid: "partial"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(await !store.isExpectedOrArrived(cid: "partial"), "The CID is still waiting.")
        #expect(await waiter.value is UploadInterruptedError)
        #expect(uploadTempFiles().subtracting(filesBefore).isEmpty)
        #endif
    }

    /// Checks that a body that goes quiet makes the server close the connection and fail the waiting CID.
    @Test func stalledBodyTimesOut() async throws {
        #if canImport(FoundationNetworking)
        // The test does not run on Linux.
        return
        #else
        let transport = HTTPSSETransport(server: SmallUploadServer(), host: "127.0.0.1", port: 0)
        transport.requestReadTimeout = 0.3
        try await transport.start()
        defer { Task { try? await transport.stop() } }

        let store = transport.pendingUploadStore
        let waiter = Task { () -> Error? in
            do {
                _ = try await store.waitForUpload(cid: "stalled", progressToken: nil, sessionID: UUID())
                return nil
            } catch {
                return error
            }
        }
        try await waitUntilExpected("stalled", in: store)

        // The socket sends one chunk, then waits for the server to close it.
        let start = Date()
        let answer = sendRaw("POST /mcp/uploads/stalled HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n", port: transport.port)
        #expect(Date().timeIntervalSince(start) < 0.9)
        #expect(answer.hasPrefix("HTTP/1.1 408"))

        let deadline = Date().addingTimeInterval(3)
        while await store.isExpectedOrArrived(cid: "stalled"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(await !store.isExpectedOrArrived(cid: "stalled"), "The CID is still waiting.")
        #expect(await waiter.value is UploadInterruptedError)
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

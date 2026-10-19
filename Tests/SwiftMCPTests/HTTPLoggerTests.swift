import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import SwiftMCP

/// Tests how the HTTP logger tracks stream connections across requests.
@Suite("HTTP logger")
struct HTTPLoggerTests {
    /// Checks that a refused stream request does not make later requests look like a stream.
    @Test func refusedStreamRequestDoesNotStick() throws {
        let logger = HTTPLogger()
        let channel = EmbeddedChannel(handler: logger)

        try channel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        #expect(logger.isSSEConnection)

        try channel.writeOutbound(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .notFound)))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        #expect(!logger.isSSEConnection)

        try channel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .POST, uri: "/oauth/token")))
        #expect(!logger.isSSEConnection)
        #expect(!logger.logsBodies)
        _ = try channel.finish()
    }

    /// Checks that an open stream keeps the stream branch.
    @Test func openStreamStaysOnTheStreamBranch() throws {
        let logger = HTTPLogger()
        let channel = EmbeddedChannel(handler: logger)

        try channel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/sse")))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        try channel.writeOutbound(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok)))
        #expect(logger.isSSEConnection)
        #expect(logger.logsBodies)
        _ = try channel.finish()
    }
}

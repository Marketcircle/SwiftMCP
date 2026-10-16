import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// A channel handler that logs both incoming and outgoing HTTP messages
/// It's unchecked Sendable because we use NIOLock for sequential access to request/response state
final class HTTPLogger: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    internal lazy var httpLogger = Logger(label: "com.cocoanetics.SwiftMCP.HTTP")
    internal lazy var sseLogger = Logger(label: "com.cocoanetics.SwiftMCP.SSE")
    internal let lock = NIOLock()

    // Track current request/response state
    internal var currentRequestHead: HTTPRequestHead?
    internal var currentRequestBody = ""
    internal var currentResponseHead: HTTPResponseHead?
    internal var currentResponseBody = ""
    internal var isSSEConnection = false
    /// A Boolean value indicating whether the current exchange's bodies may appear in the log.
    internal var logsBodies = true

    /// Log incoming requests and forward them to the next handler
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        lock.withLock {
            switch reqPart {
                case .head(let head):
                    // Check if this is an SSE connection
                    if head.uri.hasPrefix("/sse") || (head.uri.hasPrefix("/mcp") && head.method == .GET) {
                        isSSEConnection = true
                    }

                    // Log previous request if exists
                    logCurrentRequest()

                    currentRequestHead = head
                    currentRequestBody = ""
                    logsBodies = Self.showsBodies(for: head.uri)

                case .body(let buffer):
                    if logsBodies, httpLogger.logLevel <= .trace,
                       let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                        currentRequestBody += str
                    }

                case .end:
                    logCurrentRequest()
                    currentRequestHead = nil
                    currentRequestBody = ""
            }
        }

        context.fireChannelRead(data)
    }

    /// Log outgoing responses and forward them to the next handler
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let resPart = unwrapOutboundIn(data)

        lock.withLock {
            switch resPart {
                case .head(let head):
                    // For SSE connections, only log the initial response headers
                    if isSSEConnection {
                        var log = "HTTP/\(head.version.major).\(head.version.minor) \(head.status.code) \(head.status.reasonPhrase)\n"
                        log += Self.headerLines(head.headers)
                        log += "\n"
                        sseLogger.info("Connection Established:\n\(log)")
                    } else {
                        // Log previous response if exists
                        logCurrentResponse()
                        currentResponseHead = head
                        currentResponseBody = ""
                    }

                case .body(let body):
                    if case .byteBuffer(let buffer) = body {
                        if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                            if isSSEConnection {
                                // For SSE, log each message immediately
                                sseLogger.trace("SSE: \(str.truncatedForLog)")
                            } else if logsBodies, httpLogger.logLevel <= .trace {
                                currentResponseBody += str
                            }
                        }
                    }

                case .end:
                    if !isSSEConnection {
                        logCurrentResponse()
                        currentResponseHead = nil
                        currentResponseBody = ""
                    }
            }
        }

        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        context.flush()
    }

    internal func logCurrentRequest() {
        guard let head = currentRequestHead else { return }

        var log = "\(head.method) \(head.uri) HTTP/\(head.version.major).\(head.version.minor)\n"
        log += Self.headerLines(head.headers)
        log += "\n"  // Empty line after headers

        if !currentRequestBody.isEmpty {
            log += currentRequestBody.truncatedForLog + "\n"
        }

        httpLogger.trace("\(log)")
    }

    internal func logCurrentResponse() {
        guard let head = currentResponseHead else { return }

        var log = "HTTP/\(head.version.major).\(head.version.minor) \(head.status.code) \(head.status.reasonPhrase)\n"
        log += Self.headerLines(head.headers)
        log += "\n"  // Empty line after headers

        if !currentResponseBody.isEmpty {
            log += currentResponseBody.truncatedForLog + "\n"
        }

        httpLogger.trace("\(log)")
    }

    /// The path prefixes of the OAuth routes, whose bodies a log line never shows.
    static let credentialPathPrefixes = ["/authorize", "/oauth/", "/userinfo", "/u/"]

    /// Returns whether a log line may show the bodies of a request to the given URI.
    static func showsBodies(for uri: String) -> Bool {
        !credentialPathPrefixes.contains { uri.hasPrefix($0) }
    }

    /// The lowercase names of the headers whose values a log line masks.
    static let maskedHeaderNames: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie"]

    /// Returns one `name: value` line per header, with credential values masked.
    static func headerLines<Headers: Sequence>(_ headers: Headers) -> String where Headers.Element == (name: String, value: String) {
        headers.map { name, value in
            let shown = maskedHeaderNames.contains(name.lowercased()) ? "<redacted>" : value
            return "\(name): \(shown)\n"
        }.joined()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        lock.withLock {
            currentRequestHead = nil
            currentRequestBody = ""
            currentResponseHead = nil
            currentResponseBody = ""
            isSSEConnection = false
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        lock.withLock {
            // Log any pending messages
            logCurrentRequest()
            if !isSSEConnection {
                logCurrentResponse()
            }

            // Clear state
            currentRequestHead = nil
            currentRequestBody = ""
            currentResponseHead = nil
            currentResponseBody = ""
            isSSEConnection = false
        }
    }
}

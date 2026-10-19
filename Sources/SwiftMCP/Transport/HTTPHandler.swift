import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@preconcurrency import NIOCore
import NIOHTTP1
import Logging


/// HTTP request handler for the SSE transport.
///
/// Manages the NIO state machine and dispatches to the router.
/// Body chunks are always streamed via `AsyncStream<Data>`. The dispatch
/// layer collects them into `Data` for buffered handlers, or forwards
/// the stream for streaming handlers.
final class HTTPHandler: NSObject, ChannelInboundHandler, Identifiable, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestState: RequestState = .idle
    /// The cutoff record of the request whose body is streaming.
    private var currentBodyCutoff: BodyCutoff?
    /// The timer that closes the connection when the client goes quiet while the server reads a request.
    private var readTimer: Scheduled<Void>?
    /// The timer that closes the connection when one request body takes too long in total.
    private var bodyDeadline: Scheduled<Void>?
    /// The number of request heads this connection has received.
    private var requestCount = 0
    /// The number of the last request whose response has started.
    private var answeredCount = 0
    /// The number of the last request whose response has been written in full.
    private var respondedCount = 0
    private let transport: HTTPSSETransport
    let id = UUID()

    internal let logger = Logger(label: "com.cocoanetics.SwiftMCP.HTTPHandler")

    init(transport: HTTPSSETransport) {
        self.transport = transport
    }

    // MARK: - Channel Handler

    /// Starts waiting for the first request head when the handler joins a channel that is already active.
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            restartReadTimer(context: context)
        }
    }

    /// Starts waiting for the first request head and passes the event on.
    func channelActive(context: ChannelHandlerContext) {
        restartReadTimer(context: context)
        transport.markConnectionIdle(context.channel)
        context.fireChannelActive()
    }

    /// Ends a body that is still streaming and passes the event on.
    func channelInactive(context: ChannelHandlerContext) {
        cancelRequestTimers()
        if case .streaming(_, let continuation, _) = requestState {
            currentBodyCutoff?.record(.disconnected)
            continuation.finish()
            requestState = .idle
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    // MARK: - State Machine

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = unwrapInboundIn(data)

        switch (requestPart, requestState) {

        // HEAD — create stream and dispatch handler immediately
        case (.head(let head), _):
            requestCount += 1
            transport.markConnectionBusy(context.channel)
            let sizeLimit = maxBodySize(for: head)
            if let contentLength = head.headers.first(name: "content-length"),
               let length = Int(contentLength), length > sizeLimit {
                logger.warning("Rejecting request with Content-Length \(length) > max \(sizeLimit)")
                cancelRequestTimers()
                rejectOversizedRequest(context: context)
                requestState = .rejected
                // An upload route still runs, with an empty and flagged body.
                if head.uri.hasPrefix("/mcp/uploads") {
                    let (stream, continuation) = AsyncStream<Data>.makeStream()
                    let bodyCutoff = BodyCutoff()
                    bodyCutoff.record(.tooLarge)
                    continuation.finish()
                    dispatchRoute(context: context, head: head, bodyStream: stream, bodyCutoff: bodyCutoff)
                }
                return
            }

            let (stream, continuation) = AsyncStream<Data>.makeStream()
            let bodyCutoff = BodyCutoff()
            currentBodyCutoff = bodyCutoff
            requestState = .streaming(head: head, continuation: continuation, bytesWritten: 0)
            restartReadTimer(context: context)
            startBodyDeadline(context: context)
            dispatchRoute(context: context, head: head, bodyStream: stream, bodyCutoff: bodyCutoff)

        // BODY — yield chunk into the stream
        case (.body(let buffer), .streaming(let head, let continuation, let bytesWritten)):
            let sizeLimit = maxBodySize(for: head)
            let newTotal = bytesWritten + buffer.readableBytes
            guard newTotal <= sizeLimit else {
                logger.warning("Rejecting request: body size \(newTotal) > max \(sizeLimit)")
                currentBodyCutoff?.record(.tooLarge)
                cancelRequestTimers()
                continuation.finish()
                rejectOversizedRequest(context: context)
                requestState = .rejected
                return
            }
            if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                continuation.yield(Data(bytes))
            }
            requestState = .streaming(head: head, continuation: continuation, bytesWritten: newTotal)
            restartReadTimer(context: context)

        // END — finish the stream
        case (.end, .streaming(_, let continuation, _)):
            defer {
                requestState = .idle
                if respondedCount == requestCount {
                    transport.markConnectionIdle(context.channel)
                }
            }
            cancelRequestTimers()
            continuation.finish()

        // Rejection / unexpected states
        case (.body, .rejected), (.end, .rejected):
            if case .end = requestPart { requestState = .idle }
        case (.body, _):
            logger.warning("Received unexpected body without a valid head")
        case (.end, .idle):
            logger.warning("Received end without prior request state")
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    // MARK: - Route Dispatch

    /// Match the route and dispatch the handler. For buffered handlers, the body
    /// stream is collected into `Data` first. For streaming handlers, the stream
    /// is passed directly.
    private func dispatchRoute(context: ChannelHandlerContext, head: HTTPRequestHead, bodyStream: AsyncStream<Data>, bodyCutoff: BodyCutoff) {
        let channel = context.channel
        let (path, queryParams) = parseURI(head.uri)

        let requestNumber = requestCount

        guard let method = convertMethod(head.method),
              let routeMatch = transport.router.match(method: method, path: path) else {
            if claimResponse(for: requestNumber) {
                sendResponse(channel: channel, status: .notFound)
                respondedCount = requestNumber
            }
            return
        }

        let handler = routeMatch.route.handler

        let request = HTTPRouteRequest<AsyncStream<Data>>(
            method: method, uri: head.uri, path: path,
            headers: convertHeaders(head.headers), body: bodyStream,
            pathParams: routeMatch.pathParams, queryParams: queryParams,
            bodyCutoff: bodyCutoff
        )

        Task {
            let response: RouteResponse
            do {
                response = try await handler(self.transport, request)
            } catch {
                self.logger.error("Route handler error: \(error)")
                response = RouteResponse(status: .internalServerError, body: Data("Internal Server Error".utf8))
            }

            // The route answers only when the handler has not already answered this request.
            let claimed = (try? await channel.eventLoop.submit { self.claimResponse(for: requestNumber) }.get()) ?? false
            guard claimed else {
                // A refused stream gives its session's stream slot back.
                if response.bodyStream != nil, let id = response.streamSessionID,
                   let session = await self.transport.sessionManager.existingSession(id: id) {
                    await session.releaseSSEContinuation()
                }
                return
            }

            // For SSE streaming responses, register the NIO channel.
            // Legacy /sse does not emit Mcp-Session-Id, so prefer the explicit streamSessionID.
            if response.bodyStream != nil {
                if let sessionUUID = response.streamSessionID {
                    self.transport.registerSSEChannel(channel, id: sessionUUID)
                } else if let sessionId = response.headers.first(where: { $0.0.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame })?.1,
                          let sessionUUID = UUID(uuidString: sessionId) {
                    self.transport.registerSSEChannel(channel, id: sessionUUID)
                }
            }

            await self.writeRouteResponse(response, to: channel)
            channel.eventLoop.execute {
                self.finishResponse(for: requestNumber, on: channel)
            }
        }
    }

    // MARK: - Response Writing

    private func writeRouteResponse(_ response: RouteResponse, to channel: Channel) async {
        var nioHeaders = HTTPHeaders()
        for (name, value) in response.headers {
            nioHeaders.add(name: name, value: value)
        }
        if nioHeaders["Access-Control-Allow-Origin"].isEmpty,
           let origin = transport.allowedOrigins?.first, !origin.isEmpty {
            nioHeaders.add(name: "Access-Control-Allow-Origin", value: origin)
        }

        let status = nioStatus(response.status)

        if let stream = response.bodyStream {
            // The pipelining handler is removed on SSE connections so the channel keeps reading.
            let isEventStream = nioHeaders["Content-Type"].contains { $0.lowercased().hasPrefix("text/event-stream") }
            if isEventStream, let pipelining = try? await channel.pipeline.handler(type: HTTPServerPipelineHandler.self).get() {
                try? await channel.pipeline.removeHandler(pipelining).get()
            }

            // For streaming responses (SSE), don't set Content-Length.
            // Write head immediately so the client can start consuming.
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: nioHeaders)
            channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)

            for await chunk in stream {
                let buffer = channel.allocator.buffer(data: chunk)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
                channel.flush()
            }

            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        } else {
            var body: ByteBuffer? = nil
            if let data = response.body {
                body = channel.allocator.buffer(data: data)
            }
            sendResponse(channel: channel, status: status, headers: nioHeaders, body: body)
        }
    }

    // MARK: - Helpers

    /// Starts the read timer over from now, unless the transport turns the timeout off.
    private func restartReadTimer(context: ChannelHandlerContext) {
        readTimer?.cancel()
        readTimer = schedule(after: transport.requestReadTimeout, context: context)
    }

    /// Starts the deadline for the whole body of the request that just began.
    private func startBodyDeadline(context: ChannelHandlerContext) {
        bodyDeadline?.cancel()
        bodyDeadline = schedule(after: transport.requestBodyDeadline, context: context)
    }

    /// Records that the given request's response is written, and marks the connection idle when no request is in progress.
    private func finishResponse(for request: Int, on channel: Channel) {
        respondedCount = max(respondedCount, request)
        if requestCount == request, case .idle = requestState {
            transport.markConnectionIdle(channel)
        }
    }

    /// Marks the given request as answered and returns whether no response had started for it yet.
    private func claimResponse(for request: Int) -> Bool {
        guard answeredCount < request else { return false }
        answeredCount = request
        return true
    }

    /// Stops the read timer and the body deadline.
    private func cancelRequestTimers() {
        readTimer?.cancel()
        readTimer = nil
        bodyDeadline?.cancel()
        bodyDeadline = nil
    }

    /// Returns a task that times the request out after the given seconds, or nil when the value turns the timeout off.
    private func schedule(after seconds: TimeInterval, context: ChannelHandlerContext) -> Scheduled<Void>? {
        guard seconds > 0, seconds.isFinite else { return nil }
        // The cap of about 31 years keeps the nanosecond count inside Int64.
        let nanoseconds = Int64(min(seconds, 1_000_000_000) * 1_000_000_000)
        let channel = context.channel
        return context.eventLoop.scheduleTask(in: .nanoseconds(nanoseconds)) { [weak self] in
            self?.timeOutRequest(channel: channel)
        }
    }

    /// Ends a request whose body is streaming with a 408, and closes the connection.
    private func timeOutRequest(channel: Channel) {
        cancelRequestTimers()
        if case .streaming(_, let continuation, _) = requestState {
            logger.warning("Closing a connection whose request body went quiet or ran too long")
            currentBodyCutoff?.record(.timedOut)
            continuation.finish()
            requestState = .rejected
            if claimResponse(for: requestCount) {
                var headers = HTTPHeaders()
                headers.add(name: "Connection", value: "close")
                sendResponse(channel: channel, status: .requestTimeout, headers: headers)
            }
        } else {
            logger.info("Closing a connection that sent no request in time")
        }
        channel.close(promise: nil)
    }

    private func maxBodySize(for head: HTTPRequestHead) -> Int {
        if head.uri.hasPrefix("/mcp/uploads"),
           let uploadHandler = transport.server as? MCPFileUploadHandling {
            return uploadHandler.maxUploadSize
        }
        return transport.maxMessageSize
    }

    private func rejectOversizedRequest(context: ChannelHandlerContext) {
        guard claimResponse(for: requestCount) else {
            context.close(promise: nil)
            return
        }
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        let message = "Request body exceeds maximum allowed size of \(transport.maxMessageSize) bytes."
        var buffer = context.channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        sendResponse(channel: context.channel, status: .payloadTooLarge, headers: headers, body: buffer)
        context.close(promise: nil)
    }

    private func convertMethod(_ nioMethod: NIOHTTP1.HTTPMethod) -> RouteMethod? {
        switch nioMethod {
        case .GET: return .GET
        case .POST: return .POST
        case .PUT: return .PUT
        case .DELETE: return .DELETE
        case .PATCH: return .PATCH
        case .OPTIONS: return .OPTIONS
        case .HEAD: return .HEAD
        default: return nil
        }
    }

    private func nioStatus(_ status: HTTPStatus) -> HTTPResponseStatus {
        HTTPResponseStatus(statusCode: status.rawValue)
    }

    private func parseURI(_ uri: String) -> (path: String, queryParams: [(String, String)]) {
        guard let questionMark = uri.firstIndex(of: "?") else {
            return (uri, [])
        }
        let path = String(uri[..<questionMark])
        let queryString = String(uri[uri.index(after: questionMark)...])
        let queryParams = queryString.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first.flatMap({ String($0).removingPercentEncoding }) else { return nil }
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
            return (key, value)
        }
        return (path, queryParams)
    }

    private func convertHeaders(_ nioHeaders: HTTPHeaders) -> [(String, String)] {
        nioHeaders.map { ($0.name, $0.value) }
    }

    private func sendResponse(channel: Channel, status: HTTPResponseStatus, headers: HTTPHeaders? = nil, body: ByteBuffer? = nil) {
        var responseHeaders = headers ?? HTTPHeaders()
        if let origin = transport.allowedOrigins?.first, !origin.isEmpty {
            responseHeaders.add(name: "Access-Control-Allow-Origin", value: origin)
        }

        if let body = body {
            if responseHeaders["Content-Type"].isEmpty {
                responseHeaders.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            }
            responseHeaders.add(name: "Content-Length", value: "\(body.readableBytes)")
        } else {
            responseHeaders.add(name: "Content-Length", value: "0")
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: responseHeaders)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if let body = body {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }
}

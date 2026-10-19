import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix

/**
 A transport that exposes an HTTP server with Server-Sent Events (SSE) and JSON-RPC endpoints.
 
 This transport is built on top of SwiftNIO and allows clients to connect via HTTP to interact
 with the MCPServer. It provides:
 
 - Server-Sent Events (SSE) for real-time updates
 - JSON-RPC over HTTP for command processing
 - Optional OpenAPI endpoints for API documentation
 - Configurable authorization
 - Keep-alive mechanisms
 */
public final class HTTPSSETransport: Transport, @unchecked Sendable {
    /// The MCP server instance that this transport exposes.
    public let server: MCPServer

    /// The hostname or IP address on which the HTTP server listens.
    public let host: String

    /// The port number on which the HTTP server listens.
    /// If initialized with `0`, the system will select an available port
    /// when the server starts. The actual bound port is then available
    /// via this property after ``start()`` completes.
    public private(set) var port: Int

    /// Logger for logging transport events and errors.
    public let logger = Logger(label: "com.cocoanetics.SwiftMCP.HTTPSSETransport")

    internal let group: EventLoopGroup
    internal var channel: Channel?
    internal lazy var sessionManager = SessionManager(transport: self)
    internal let pendingUploadStore = PendingUploadStore()
    internal var keepAliveTimer: DispatchSourceTimer?
    /// The lock that serializes every change to `keepAliveTimer` and `sessionSweepTimer`.
    private let keepAliveLock = NSLock()
    /// The timer that removes idle sessions.
    private var sessionSweepTimer: DispatchSourceTimer?
    /// The number of connections open now.
    private var openConnections = 0
    /// The connection cap in force, set from ``maxConnections`` and the open-file limit when the server starts.
    private var connectionLimit = Int.max
    /// The number of connections refused since the server last took one.
    private var refusedInARow = 0
    /// The connections waiting for their next request, with the time each went idle.
    private var idleConnections: [ObjectIdentifier: (channel: Channel, since: NIODeadline)] = [:]
    /// The connections closed to make room, until each close completes.
    private var evictedConnections: Set<ObjectIdentifier> = []
    /// The seconds a connection must sit idle before a new connection may close it, 5 by default.
    internal var minimumIdleAge: TimeInterval = 5
    /// The lock that guards ``openConnections``, ``connectionLimit``, ``refusedInARow``, ``idleConnections``, and ``evictedConnections``.
    private let connectionLock = NSLock()

    /// The HTTP router that dispatches incoming requests to route handlers.
    internal lazy var router: Router = buildRouter()

    /// Custom routes registered by the user via `addRoute`.
    internal var customRoutes: [HTTPRoute] = []

    /// Flag to determine whether to serve OpenAPI endpoints.
    public var serveOpenAPI: Bool = false

    /// The lifetime in seconds of an access token that comes without `expires_in`.
    static let defaultAccessTokenLifetime = 60 * 60

    /// The seconds a client may go quiet while the server reads its request, from connecting to the first head and between body chunks, 30 by default. Zero or less turns the timeout off. A keep-alive connection that sits idle between requests has no timeout.
    public var requestReadTimeout: TimeInterval = 30

    /// The seconds one request body may take in total, uploads included, 300 by default. Zero or less turns the deadline off.
    public var requestBodyDeadline: TimeInterval = 300

    /// The most connections the server keeps open at once, 256 by default and never more than half the open-file limit. Zero or less removes the cap. The server reads it in ``start()``.
    ///
    /// At the cap, a new connection closes the longest-idle connection that has waited at least 5 s, or is refused when there is none.
    public var maxConnections: Int = 256

    /// The most sessions the server keeps at once, 64 by default.
    public var maxSessions: Int = 64

    /// The seconds between sweeps for idle sessions, 60 by default. The server reads it in ``start()``, and zero or less turns the sweep off.
    public var sessionSweepInterval: TimeInterval = 60

    /// The seconds a session with no open stream may stay idle before removal, 30 minutes by default.
    public var sessionIdleTimeout: TimeInterval = 30 * 60

    /// A Boolean value indicating whether the server's URLs honor `X-Forwarded-*` headers.
    public var trustsForwardedHeaders: Bool = false
    
    /// Maximum allowed HTTP message size in bytes (defaults to 4 MB).
    public var maxMessageSize: Int = 4 * 1024 * 1024

    /// Result of an authorization check.
    public enum AuthorizationResult: Sendable {
        case authorized
        case unauthorized(String)
        case jweNotSupported(String)
        /// The server has no room for another session.
        case tooManySessions

        /// A Boolean value indicating whether the result lets the request through.
        var isAuthorized: Bool {
            if case .authorized = self { return true }
            return false
        }
    }

    /// A function type that handles authorization of requests.
    public typealias AuthorizationHandler = @Sendable (String?) -> AuthorizationResult

    /// Origins allowed in CORS `Access-Control-Allow-Origin` headers.
    ///
    /// - `nil` (default): no CORS header is emitted.
    /// - Empty array: same as `nil`.
    /// - `["*"]`: wildcard (allows any origin — use only for local development).
    /// - `["https://example.com"]`: restrict to specific origins.
    public var allowedOrigins: [String]?

    /// Authorization handler for bearer tokens.
    public var authorizationHandler: AuthorizationHandler = { _ in return .authorized }

    /// Optional OAuth configuration. When set, incoming bearer tokens are
    /// validated using the provided settings and `.well-known` endpoints are
    /// served with the corresponding metadata.
    public var oauthConfiguration: OAuthConfiguration?

    /// Perform authorization using either the OAuth configuration or the
    /// synchronous ``authorizationHandler`` closure.
    func authorize(_ token: String?, sessionID: UUID?) async -> AuthorizationResult {
        if let rejection = rejectJWE(token) {
            return rejection
        }

        // 1. If we have a session ID, check token against session-stored value
        if let id = sessionID {
            if let session = await sessionManager.existingSession(id: id) {
                let result = await authorize(token, session: session)
                if result.isAuthorized {
                    await session.markActive()
                }
                return result
            }
            return await authorizeNewSession(id: id, token: token)
        }

        // 2. If we don't have a sessionID, see if we can locate a session by token.
        if let token, sessionID == nil {
            if await sessionManager.session(forToken: token) != nil {
                // Without OAuth, the handler decides every request.
                return oauthConfiguration == nil ? authorizationHandler(token) : .authorized
            }
        }

        // 3. For tokens without session context, validate them
        if let token {
            let isValid = await validateNewToken(token)
            return isValid ? .authorized : .unauthorized("Invalid token - token exchange required")
        }

        // 4. If OAuth is configured, require authentication
        if oauthConfiguration != nil {
            guard let token = token, !token.isEmpty else {
                return .unauthorized("Authentication required")
            }
            return .unauthorized("Invalid token - token exchange required")
        }
        
        // 5. Otherwise use legacy handler (for unauthenticated mode)
        return authorizationHandler(token)
    }

    /// Authorizes a request for a session that does not exist yet, and creates the session only when its token passes.
    private func authorizeNewSession(id: UUID, token: String?) async -> AuthorizationResult {
        guard let token else {
            if oauthConfiguration != nil {
                return .unauthorized("Authentication required")
            }
            return authorizationHandler(nil)
        }
        guard await validateNewToken(token) else {
            return .unauthorized("Invalid token - token exchange required")
        }
        guard let session = await sessionManager.session(id: id, limit: maxSessions) else {
            return .tooManySessions
        }
        await bind(token, to: session)
        return .authorized
    }

    /// Stores a validated token on the session, with an expiry and user info under OAuth.
    private func bind(_ token: String, to session: Session) async {
        await session.setAccessToken(token)
        if let oauthConfiguration {
            // A token without expires_in gets the default lifetime.
            await session.setAccessTokenExpiry(Date().addingTimeInterval(TimeInterval(Self.defaultAccessTokenLifetime)))
            await sessionManager.fetchAndStoreUserInfo(for: session.id, oauthConfiguration: oauthConfiguration)
        }
    }

    /// Authorizes a token against a session that already exists, without creating one.
    func authorize(_ token: String?, session: Session) async -> AuthorizationResult {
        if let rejection = rejectJWE(token) {
            return rejection
        }
        if let stored = await session.accessToken {
            guard let token, stored.constantTimeEquals(token) else {
                return .unauthorized("Invalid or expired token")
            }
            // Without OAuth, the handler decides every request.
            guard oauthConfiguration != nil else {
                return authorizationHandler(token)
            }
            if (await session.accessTokenExpiry ?? Date.distantFuture) > Date() {
                return .authorized
            }
            return .unauthorized("Invalid or expired token")
        } else if let token {
            // First time we see a token for this session - validate it before accepting
            let isValid = await validateNewToken(token)
            if isValid {
                await bind(token, to: session)
                return .authorized
            } else {
                return .unauthorized("Invalid token - token exchange required")
            }
        } else {
            // No token provided for this session
            // If OAuth is configured, require authentication
            if oauthConfiguration != nil {
                return .unauthorized("Authentication required")
            }
            // Otherwise use legacy handler (for unauthenticated mode)
            return authorizationHandler(token)
        }
    }

    /// Returns the rejection for an encrypted token outside proxy mode, or nil.
    private func rejectJWE(_ token: String?) -> AuthorizationResult? {
        // A JWE token has 5 segments: header.encrypted_key.iv.ciphertext.tag
        guard let token, token.split(separator: ".").count == 5 else {
            return nil
        }
        if let oauthConfiguration, oauthConfiguration.transparentProxy {
            // In proxy mode, we can handle JWE tokens by proxying them
            return nil
        }
        let audience = oauthConfiguration?.audience ?? "your-api"
        return .jweNotSupported("Encrypted (JWE) tokens are not supported. Use a signed JWT (JWS) with audience=\(audience)")
    }

    /// Validate a new token using OAuth configuration or authorization handler
    internal func validateNewToken(_ token: String) async -> Bool {
        // If we have OAuth configuration, use its validation
        if let oauthConfiguration {
            // In transparent proxy mode, only accept tokens that are already stored in a session
            // This ensures we only trust tokens that came through our proxy
            if oauthConfiguration.transparentProxy {
                // Check if this token is already stored in any session
                if await sessionManager.session(forToken: token) != nil {
                    return true
                }
            }
            
            // Try OAuth validation for non-proxy mode
            let oauthValid = await oauthConfiguration.validate(token: token)
            if oauthValid {
                return true
            }
            
            return false
        }
        
        // Fallback to authorization handler
        switch authorizationHandler(token) {
        case .authorized:
            return true
        case .unauthorized:
            return false
        case .jweNotSupported:
            return false
        case .tooManySessions:
            return false
        }
    }

    /// Defines the available keep-alive modes for maintaining connections.
    public enum KeepAliveMode: Sendable {
        case none
        case sse
        case ping
    }

    /// The current keep-alive mode for the transport.
    public var keepAliveMode: KeepAliveMode = .ping {
        didSet {
            if oldValue != keepAliveMode {
                if keepAliveMode == .none {
                    stopKeepAliveTimer()
                } else {
                    startKeepAliveTimer()
                }
            }
        }
    }

    /// The number of seconds between keep-alive messages, 60 by default. A value of zero or less is ignored.
    public var keepAliveInterval: TimeInterval {
        get { keepAliveLock.withLock { storedKeepAliveInterval } }
        set {
            guard newValue > 0 else {
                return
            }
            keepAliveLock.withLock {
                storedKeepAliveInterval = newValue
                if keepAliveTimer != nil {
                    restartKeepAliveTimerLocked()
                }
            }
        }
    }

    /// The keep-alive interval, read and written only under `keepAliveLock`.
    private var storedKeepAliveInterval: TimeInterval = 60

    /// The number of active SSE channels currently connected to the server.
    var sseChannelCount: Int {
        get async { await sessionManager.channelCount }
    }


    // MARK: - Initialization

    public init(server: MCPServer, host: String = "127.0.0.1", port: Int = 8080) {
        self.server = server
        self.host = host
        self.port = port
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public convenience init(server: MCPServer) {
        self.init(server: server, host: "127.0.0.1", port: 8080)
    }

    // MARK: - Server Lifecycle

    public func start() async throws {
        let limit = effectiveConnectionLimit()
        connectionLock.withLock { connectionLimit = limit }

        let bootstrap = ServerBootstrap(group: group)
			.serverChannelOption(ChannelOptions.backlog, value: 256)
			.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelInitializer {  channel in
            switch self.admitConnection() {
            case .refused(let logRefusal):
                if logRefusal {
                    self.logger.warning("Refusing new connections because the connection cap is reached and none is idle")
                }
                return channel.eventLoop.makeFailedFuture(ConnectionLimitError())
            case .admitted(let evicted):
                if let evicted {
                    self.logger.debug("Closing the longest-idle connection to make room")
                    evicted.close(promise: nil)
                }
            }
            channel.closeFuture.whenComplete { _ in
                self.releaseConnection(channel)
            }
            return channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(HTTPLogger())
            }.flatMap {
                channel.pipeline.addHandler(HTTPHandler(transport: self))
            }
        }
			.childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
			.childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        do {
            self.channel = try await bootstrap.bind(host: host, port: self.port).get()
            if let actualPort = self.channel?.localAddress?.port {
                self.port = actualPort
            }
            logger.info("Server started and listening on \(host):\(self.port)")
            startKeepAliveTimer()
            startSessionSweepTimer()

            self.channel?.closeFuture.whenComplete { [logger] result in
                switch result {
                    case .success:
                        logger.info("Server channel closed normally")
                    case .failure(let error):
                        logger.error("Server channel closed with error: \(error)")
                }
            }
        } catch let error as IOError {
            let errorMessage: String
            switch error.errnoCode {
                case EADDRINUSE:
                    errorMessage = "Port \(port) is already in use. Please choose a different port or ensure no other service is using this port."
                case EACCES:
                    errorMessage = "Permission denied to bind to port \(port). This port may require elevated privileges."
                case EADDRNOTAVAIL:
                    errorMessage = "The address \(host) is not available for binding."
                default:
                    errorMessage = "Failed to bind to \(host):\(port). Error: \(error.localizedDescription)"
            }
            logger.error("\(errorMessage)")
            throw TransportError.bindingFailed(errorMessage)
        } catch {
            logger.error("Server error: \(error)")
            throw TransportError.bindingFailed(error.localizedDescription)
        }
    }

    public func run() async throws {
        try await start()
        try await channel?.closeFuture.get()
    }

    public func stop() async throws {
        logger.info("Stopping server...")
        stopKeepAliveTimer()
        stopSessionSweepTimer()

        await sessionManager.removeAllSessions()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        logger.info("Server stopped")
    }

    /// Starts the keep-alive timer at `keepAliveInterval`, replacing any running one.
    internal func startKeepAliveTimer() {
        keepAliveLock.withLock {
            restartKeepAliveTimerLocked()
        }
        logger.trace("Started keep-alive timer")
    }

    /// Stop the keep-alive timer.
    internal func stopKeepAliveTimer() {
        keepAliveLock.withLock {
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
        }
        logger.trace("Stopped keep-alive timer")
    }

    /// Starts the idle session timer at ``sessionSweepInterval``, replacing any running one.
    private func startSessionSweepTimer() {
        let interval = sessionSweepInterval
        guard interval > 0 else { return }
        keepAliveLock.withLock {
            sessionSweepTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                Task { await self.sessionManager.removeIdleSessions(olderThan: self.sessionIdleTimeout) }
            }
            timer.resume()
            sessionSweepTimer = timer
        }
    }

    /// Stops the idle session timer.
    private func stopSessionSweepTimer() {
        keepAliveLock.withLock {
            sessionSweepTimer?.cancel()
            sessionSweepTimer = nil
        }
    }

    /// Starts a new keep-alive timer at `keepAliveInterval` while the caller holds `keepAliveLock`.
    private func restartKeepAliveTimerLocked() {
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now(), repeating: storedKeepAliveInterval)
        timer.setEventHandler { [weak self] in
            self?.sendKeepAlive()
        }
        timer.resume()
        keepAliveTimer = timer
    }

    /// Send a keep-alive message to all connected SSE clients.
    internal func sendKeepAlive() {
        Task { [weak self] in
            guard let self = self else { return }

            switch self.keepAliveMode {
                case .none:
                    return
                case .sse:
                    await self.sessionManager.forEachSession { session in
                        await session.sendSSE(SSEMessage(comment: "keep-alive"))
                    }
                case .ping:
                    await self.sessionManager.forEachSession { session in
                        // The ping goes only to sessions with an open stream.
                        guard await session.hasActiveConnection else { return }
                        Task {
                            let ping = JSONRPCMessage.request(id: .string(UUID().uuidString), method: "ping")
                            do {
                                try await session.send(ping)
                            } catch {
                                // Log error but don't fail the keep-alive cycle
                                self.logger.warning("Failed to send ping to session \(session.id): \(error)")
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Request Handling
    /// Handle a JSON-RPC request and send the response through the SSE channels.
    func handleJSONRPCRequest(_ request: JSONRPCMessage, from sessionID: UUID) {
        Task {
            let pending = server is MCPFileUploadHandling ? pendingUploadStore : nil

            guard let response = await PendingUploadResolver.$current.withValue(pending, operation: {
                await server.handleMessage(request)
            }) else {
                return
            }

            try await send(response)
        }
    }

    // MARK: - Handling SSE Connections

    /// Prepare an SSE session: create the stream, store the continuation,
    /// and return the `AsyncStream<Data>` for the route handler to include
    /// in its response. Does **not** touch the NIO channel.
    ///
    /// Returns `nil` when the session already has a stream, is missing with `createsSession` off, or would pass ``maxSessions``.
    func prepareSSEStream(sessionID: UUID, createsSession: Bool = true) async -> AsyncStream<Data>? {
        let session: Session
        if createsSession {
            guard let created = await sessionManager.session(id: sessionID, limit: maxSessions) else { return nil }
            session = created
        } else {
            guard let existing = await sessionManager.existingSession(id: sessionID) else { return nil }
            await existing.markActive()
            session = existing
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        guard await session.claimSSEContinuation(continuation) else {
            continuation.finish()
            return nil
        }
        return stream
    }

    /// Register the NIO channel for an SSE session and set up close handling.
    /// Called by `HTTPHandler` after the route handler returns a streaming response.
    func registerSSEChannel(_ channel: Channel, id: UUID) {
        Task {
            await sessionManager.register(channel: channel, id: id)
            let count = await sessionManager.channelCount
            logger.info("New SSE channel registered (total: \(count))")
        }

        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self = self else { return }
            Task {
                // Remove the entire session when the channel closes
                await self.sessionManager.removeSession(id: id, ifChannel: channel)
                let count = await self.sessionManager.channelCount
                self.logger.info("SSE channel removed (remaining: \(count))")
            }
        }
    }

    /// Send a message to a specific client.
    func sendSSE(_ message: SSEMessage, to sessionID: UUID) {
        Task {
            guard let session = await sessionManager.existingSession(id: sessionID) else {
                logger.warning("Dropped an SSE message for unknown session \(sessionID)")
                return
            }
            await session.sendSSE(message)
        }
    }

    /// Broadcast a log message to all connected clients.
    /// - Parameter message: The log message to broadcast
    public func broadcastLog(_ message: LogMessage) async {
        // Send to all connected sessions, filtered by their minimumLogLevel
        await sessionManager.broadcastLog(message)
    }

    /// Broadcast a tools list-changed notification to all connected clients.
    public func broadcastToolsListChanged() async {
        await sessionManager.broadcastToolsListChanged()
    }

    /// Broadcast a resources list-changed notification to all connected clients.
    public func broadcastResourcesListChanged() async {
        await sessionManager.broadcastResourcesListChanged()
    }

    /// Broadcast a prompts list-changed notification to all connected clients.
    public func broadcastPromptsListChanged() async {
        await sessionManager.broadcastPromptsListChanged()
    }

    /// Broadcast a resource-updated notification to all connected clients.
    /// - Parameter uri: The URI of the resource that was updated.
    public func broadcastResourceUpdated(uri: URL) async {
        await sessionManager.broadcastResourceUpdated(uri: uri)
    }


    // MARK: - Transport

    /// Send raw data to the client associated with the current `Session`.
    public func send(_ data: Data) async throws {
        precondition(Session.current != nil, "Attempted to send without an active session")
        let session = Session.current!

        let string = String(data: data, encoding: .utf8) ?? ""
        let message = SSEMessage(data: string)
        await session.sendSSE(message)
    }

    // MARK: - Route Registration

    /// Register a route with buffered input and buffered output.
    ///
    /// Must be called before ``start()``.
    public func addRoute(
        _ method: RouteMethod,
        _ path: String,
        handler: @escaping @Sendable (HTTPRouteRequest<Data?>) async throws -> HTTPRouteResponse<Data?>
    ) {
        customRoutes.append(HTTPRoute(method: method, pathPattern: path, handler: { _, request in
            RouteResponse(try await handler(request))
        }))
    }

    /// Register a route with buffered input and streaming output.
    ///
    /// Must be called before ``start()``.
    public func addRoute(
        _ method: RouteMethod,
        _ path: String,
        handler: @escaping @Sendable (HTTPRouteRequest<Data?>) async throws -> HTTPRouteResponse<AsyncStream<Data>>
    ) {
        customRoutes.append(HTTPRoute(method: method, pathPattern: path, handler: { _, request in
            RouteResponse(try await handler(request))
        }))
    }

    // MARK: - Router Assembly

    /// Build the router with all built-in and custom routes.
    internal func buildRouter() -> Router {
        let router = Router()

        // Built-in routes (order matters — first match wins)
        router.addRoutes(corsRoutes())
        router.addRoutes(mcpRoutes())
        router.addRoutes(legacySSERoutes())
        router.addRoutes(uploadRoutes())
        router.addRoutes(openAPIRoutes())
        router.addRoutes(oauthRoutes())

        // Custom routes registered by the user
        router.addRoutes(customRoutes)
        return router
    }

    /// Returns ``maxConnections`` capped at half the open-file limit, or no cap when it is zero or less.
    private func effectiveConnectionLimit() -> Int {
        guard maxConnections > 0 else { return .max }
        var limit = rlimit()
        #if os(Linux)
        let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        #else
        let resource = RLIMIT_NOFILE
        #endif
        guard getrlimit(resource, &limit) == 0 else { return maxConnections }
        let half = max(Int(clamping: limit.rlim_cur / 2), 1)
        guard half < maxConnections else { return maxConnections }
        logger.notice("Capping connections at \(half), half the open-file limit")
        return half
    }

    /// The outcome of a new connection against the connection cap.
    private enum Admission {
        /// The connection is taken, closing the given idle connection when there is one.
        case admitted(evicting: Channel?)
        /// The connection is refused, and the refusal is logged when the flag is set.
        case refused(logRefusal: Bool)
    }

    /// Returns the admission of a new connection, counting it when it fits under the cap or an idle connection makes room.
    private func admitConnection() -> Admission {
        let cutoff = NIODeadline.now() - .nanoseconds(Int64(max(minimumIdleAge, 0) * 1_000_000_000))
        return connectionLock.withLock {
            if openConnections < connectionLimit {
                openConnections += 1
                refusedInARow = 0
                return .admitted(evicting: nil)
            }
            guard let oldest = idleConnections.filter({ $0.value.since <= cutoff }).min(by: { $0.value.since < $1.value.since }) else {
                refusedInARow += 1
                return .refused(logRefusal: refusedInARow == 1)
            }
            idleConnections.removeValue(forKey: oldest.key)
            evictedConnections.insert(oldest.key)
            openConnections += 1
            refusedInARow = 0
            return .admitted(evicting: oldest.value.channel)
        }
    }

    /// Removes a closed connection from the count and from the idle list.
    private func releaseConnection(_ channel: Channel) {
        connectionLock.withLock {
            openConnections -= 1
            idleConnections.removeValue(forKey: ObjectIdentifier(channel))
            evictedConnections.remove(ObjectIdentifier(channel))
        }
    }

    /// Records that the connection waits for its next request, unless it has closed.
    internal func markConnectionIdle(_ channel: Channel) {
        guard channel.isActive else { return }
        connectionLock.withLock {
            let id = ObjectIdentifier(channel)
            guard !evictedConnections.contains(id) else { return }
            idleConnections[id] = (channel, .now())
        }
    }

    /// Records that the connection has a request in progress.
    internal func markConnectionBusy(_ channel: Channel) {
        connectionLock.withLock {
            idleConnections.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    /// Returns a 503 response when one more session would pass ``maxSessions``, or nil when there is room.
    internal func sessionLimitResponse() async -> RouteResponse? {
        guard await sessionManager.sessions.count >= maxSessions else { return nil }
        logger.warning("Refused a new session because \(maxSessions) sessions are open")
        return RouteResponse(status: .serviceUnavailable)
    }

    /// Returns the value of the given `X-Forwarded-*` header, or nil when ``trustsForwardedHeaders`` is off.
    internal func forwardedHeader(_ name: String, in request: HTTPRouteRequest<Data?>) -> String? {
        trustsForwardedHeaders ? request.header(name) : nil
    }
}

/// The error that fails the initializer of a connection past the connection cap.
struct ConnectionLimitError: Error {}

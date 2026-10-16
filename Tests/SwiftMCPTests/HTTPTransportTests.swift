import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCP


@Suite("HTTP Transport Integration")
struct HTTPTransportTests {

	/// Create a transport, start it, and return the base URL.
	private func startTransport() async throws -> (HTTPSSETransport, URL) {
		let server = Calculator()
		let transport = HTTPSSETransport(server: server, host: "127.0.0.1", port: 0)
		try await transport.start()
		let baseURL = URL(string: "http://127.0.0.1:\(transport.port)")!
		return (transport, baseURL)
	}

	/// Encode a JSON-RPC message to Data.
	private func encode(_ message: JSONRPCMessage) throws -> Data {
		try JSONEncoder().encode(message)
	}

	/// Decode a JSON-RPC message from Data.
	private func decode(_ data: Data) throws -> JSONRPCMessage {
		try JSONDecoder().decode(JSONRPCMessage.self, from: data)
	}

	/// Build the standard initialize request.
	private func initializeRequest(id: Int = 1) -> JSONRPCMessage {
		.request(
			id: id,
			method: "initialize",
			params: [
				"protocolVersion": .string("2025-06-18"),
				"capabilities": .object([:]),
				"clientInfo": .object([
					"name": .string("TestClient"),
					"version": .string("1.0")
				])
			]
		)
	}

	// MARK: - Modern Streamable HTTP (POST /mcp)

	@Test("POST /mcp: initialize without SSE returns immediate response")
	func modernInitialize() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		var request = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.httpBody = try encode(initializeRequest())

		let (data, httpResponse) = try await session.data(for: request)
		let response = httpResponse as! HTTPURLResponse

		#expect(response.statusCode == 200)
		#expect(response.value(forHTTPHeaderField: "Mcp-Session-Id") != nil)

		let message = try decode(data)
		guard case .response(let resp) = message else {
			Issue.record("Expected response, got \(message)")
			return
		}
		#expect(resp.id == .int(1))

		guard let result = resp.result,
			  let protocolVersion = result["protocolVersion"]?.value as? String else {
			Issue.record("Missing protocolVersion in result")
			return
		}
		#expect(protocolVersion == "2025-06-18")
	}

	@Test("POST /mcp: ping returns pong")
	func modernPing() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		let url = baseURL.appendingPathComponent("mcp")

		// Initialize first
		var initReq = URLRequest(url: url)
		initReq.httpMethod = "POST"
		initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		initReq.setValue("application/json", forHTTPHeaderField: "Accept")
		initReq.httpBody = try encode(initializeRequest())

		let (_, initResp) = try await session.data(for: initReq)
		let sessionId = (initResp as! HTTPURLResponse).value(forHTTPHeaderField: "Mcp-Session-Id")!

		// Ping
		let pingMessage = JSONRPCMessage.request(id: 2, method: "ping")
		var pingReq = URLRequest(url: url)
		pingReq.httpMethod = "POST"
		pingReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		pingReq.setValue("application/json", forHTTPHeaderField: "Accept")
		pingReq.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
		pingReq.httpBody = try encode(pingMessage)

		let (pingData, pingResp) = try await session.data(for: pingReq)
		let pingHTTP = pingResp as! HTTPURLResponse
		#expect(pingHTTP.statusCode == 200)

		// Session ID must be preserved across requests
		let pingSessionId = pingHTTP.value(forHTTPHeaderField: "Mcp-Session-Id")
		#expect(pingSessionId == sessionId, "Session ID changed between requests")

		let message = try decode(pingData)
		guard case .response(let resp) = message else {
			Issue.record("Expected response, got \(message)")
			return
		}
		#expect(resp.id == .int(2))
		#expect(resp.result != nil) // empty object = pong
	}

	@Test("POST /mcp: session ID is preserved across requests")
	func sessionIdPreserved() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		let url = baseURL.appendingPathComponent("mcp")

		// Request 1: Initialize
		var req1 = URLRequest(url: url)
		req1.httpMethod = "POST"
		req1.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req1.setValue("application/json", forHTTPHeaderField: "Accept")
		req1.httpBody = try encode(initializeRequest())

		let (_, resp1) = try await session.data(for: req1)
		let sessionId = (resp1 as! HTTPURLResponse).value(forHTTPHeaderField: "Mcp-Session-Id")!
		#expect(UUID(uuidString: sessionId) != nil, "Session ID is not a valid UUID")

		// Request 2: Ping with same session ID
		var req2 = URLRequest(url: url)
		req2.httpMethod = "POST"
		req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req2.setValue("application/json", forHTTPHeaderField: "Accept")
		req2.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
		req2.httpBody = try encode(JSONRPCMessage.request(id: 2, method: "ping"))

		let (_, resp2) = try await session.data(for: req2)
		let sessionId2 = (resp2 as! HTTPURLResponse).value(forHTTPHeaderField: "Mcp-Session-Id")!
		#expect(sessionId2 == sessionId, "Session ID changed: \(sessionId) → \(sessionId2)")

		// Request 3: tools/list with same session ID
		var req3 = URLRequest(url: url)
		req3.httpMethod = "POST"
		req3.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req3.setValue("application/json", forHTTPHeaderField: "Accept")
		req3.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
		req3.httpBody = try encode(JSONRPCMessage.request(id: 3, method: "tools/list"))

		let (_, resp3) = try await session.data(for: req3)
		let sessionId3 = (resp3 as! HTTPURLResponse).value(forHTTPHeaderField: "Mcp-Session-Id")!
		#expect(sessionId3 == sessionId, "Session ID changed: \(sessionId) → \(sessionId3)")
	}

	@Test("POST /mcp: with active SSE returns 202 and streams response")
	func modernSSEStreaming() async throws {
		#if canImport(FoundationNetworking)
		// URLSession.bytes(for:) is unavailable on Linux FoundationNetworking.
		return
		#else
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let url = baseURL.appendingPathComponent("mcp")
		let postSession = URLSession(configuration: .ephemeral)

		// Step 1: Initialize WITHOUT SSE to get a session ID (immediate 200 response)
		var initReq = URLRequest(url: url)
		initReq.httpMethod = "POST"
		initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		initReq.setValue("application/json", forHTTPHeaderField: "Accept")
		initReq.httpBody = try encode(initializeRequest())

		let (_, initResp) = try await postSession.data(for: initReq)
		let sessionId = (initResp as! HTTPURLResponse).value(forHTTPHeaderField: "Mcp-Session-Id")!
		#expect((initResp as! HTTPURLResponse).statusCode == 200)

		// Step 2: Open SSE connection in background Task
		// bytes(for:) blocks until first body bytes arrive.
		let receivedEvents = Box<[SSEClientMessage]>([])
		var sseReq = URLRequest(url: url)
		sseReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		sseReq.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")

		let sseTask = Task {
			let session = URLSession(configuration: .ephemeral)
			let (sseBytes, _) = try await session.bytes(for: sseReq)
			for try await message in sseBytes.lines.sseMessages() {
				receivedEvents.value.append(message)
			}
		}

		// Wait for SSE channel registration
		try await Task.sleep(for: .milliseconds(300))

		// Step 3: List tools via POST — should get 202, response via SSE
		let toolsMessage = JSONRPCMessage.request(id: 2, method: "tools/list")
		var toolsReq = URLRequest(url: url)
		toolsReq.httpMethod = "POST"
		toolsReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		toolsReq.setValue("application/json", forHTTPHeaderField: "Accept")
		toolsReq.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
		toolsReq.httpBody = try encode(toolsMessage)

		let (_, toolsResp) = try await postSession.data(for: toolsReq)
		let toolsHTTP = toolsResp as! HTTPURLResponse
		#expect(toolsHTTP.statusCode == 202)
		#expect(toolsHTTP.value(forHTTPHeaderField: "Mcp-Session-Id") == sessionId, "Session ID changed on tools/list")

		try await Task.sleep(for: .milliseconds(500))

		// Step 4: Ping via POST — should get 202
		let pingMessage = JSONRPCMessage.request(id: 3, method: "ping")
		var pingReq = URLRequest(url: url)
		pingReq.httpMethod = "POST"
		pingReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		pingReq.setValue("application/json", forHTTPHeaderField: "Accept")
		pingReq.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
		pingReq.httpBody = try encode(pingMessage)

		let (_, pingResp) = try await postSession.data(for: pingReq)
		#expect((pingResp as! HTTPURLResponse).statusCode == 202)

		try await Task.sleep(for: .milliseconds(500))

		sseTask.cancel()

		// Verify tools/list response arrived via SSE
		let toolsEvent = receivedEvents.value.first { event in
			guard let msg = try? decode(Data(event.data.utf8)),
				  case .response(let r) = msg, r.id == .int(2) else { return false }
			return true
		}
		#expect(toolsEvent != nil, "Expected tools/list response via SSE")

		if let event = toolsEvent {
			let message = try decode(Data(event.data.utf8))
			guard case .response(let resp) = message,
				  let result = resp.result,
				  let tools = result["tools"] else {
				Issue.record("Expected tools in response")
				return
			}
			// Calculator has tools (add, subtract, etc.)
			guard case .array(let toolArray) = tools else {
				Issue.record("Expected tools array")
				return
			}
			#expect(!toolArray.isEmpty, "Calculator should have tools")
		}

		// Verify ping response arrived via SSE
		let pingEvent = receivedEvents.value.first { event in
			guard let msg = try? decode(Data(event.data.utf8)),
				  case .response(let r) = msg, r.id == .int(3) else { return false }
			return true
		}
		#expect(pingEvent != nil, "Expected ping response via SSE")
		#endif
	}

	// MARK: - Legacy SSE Protocol (GET /sse + POST /messages)

	@Test("Legacy SSE: connect, get endpoint, initialize, ping")
	func legacySSEFullFlow() async throws {
		#if canImport(FoundationNetworking)
		// URLSession.bytes(for:) is unavailable on Linux FoundationNetworking.
		return
		#else
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let receivedEvents = Box<[SSEClientMessage]>([])

		// bytes(for:) blocks until first body bytes arrive,
		// so the SSE connection must be opened in a background Task.
		var sseReq = URLRequest(url: baseURL.appendingPathComponent("sse"))
		sseReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")

		let sseTask = Task {
			let session = URLSession(configuration: .ephemeral)
			let (sseBytes, _) = try await session.bytes(for: sseReq)
			for try await message in sseBytes.lines.sseMessages() {
				receivedEvents.value.append(message)
			}
		}

		// Wait for endpoint event (legacy SSE sends it immediately)
		try await Task.sleep(for: .milliseconds(500))

		let endpointEvent = receivedEvents.value.first { $0.event == "endpoint" }
		guard let endpointData = endpointEvent?.data,
			  let messagesURL = URL(string: endpointData) else {
			sseTask.cancel()
			Issue.record("Never received endpoint event. Events: \(receivedEvents.value.map { "[\($0.event)] \($0.data)" })")
			return
		}

		#expect(messagesURL.path.hasPrefix("/messages/"))

		// Extract the session ID from the endpoint URL — must be a valid UUID
		let legacySessionId = messagesURL.lastPathComponent
		#expect(UUID(uuidString: legacySessionId) != nil, "Endpoint session ID is not a valid UUID: \(legacySessionId)")

		// Initialize via POST to the messages endpoint
		let postSession = URLSession(configuration: .ephemeral)
		var initReq = URLRequest(url: messagesURL)
		initReq.httpMethod = "POST"
		initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		initReq.httpBody = try encode(initializeRequest())

		let (_, initResp) = try await postSession.data(for: initReq)
		#expect((initResp as! HTTPURLResponse).statusCode == 202)

		// Wait for SSE to deliver the initialize response.
		// Ignore later notifications like ping; explicitly look for the response with id 1.
		let deadline = Date().addingTimeInterval(2)
		var initResponse: JSONRPCMessage.JSONRPCResponseData?
		while Date() < deadline, initResponse == nil {
			for event in receivedEvents.value where event.event != "endpoint" {
				let message = try decode(Data(event.data.utf8))
				if case .response(let resp) = message, resp.id == .int(1) {
					initResponse = resp
					break
				}
			}
			if initResponse == nil {
				try await Task.sleep(for: .milliseconds(100))
			}
		}

		guard let initResponse else {
			Issue.record("Expected initialize response via SSE. All events: \(receivedEvents.value.map { "[\($0.event)] \($0.data.prefix(80))" })")
			sseTask.cancel()
			return
		}
		#expect(initResponse.id == .int(1))

		// Send initialized notification
		let initializedNotification = JSONRPCMessage.notification(method: "notifications/initialized")
		var notifReq = URLRequest(url: messagesURL)
		notifReq.httpMethod = "POST"
		notifReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		notifReq.httpBody = try encode(initializedNotification)

		let (_, notifResp) = try await postSession.data(for: notifReq)
		#expect((notifResp as! HTTPURLResponse).statusCode == 202)

		// List tools
		let toolsMessage = JSONRPCMessage.request(id: 2, method: "tools/list")
		var toolsReq = URLRequest(url: messagesURL)
		toolsReq.httpMethod = "POST"
		toolsReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		toolsReq.httpBody = try encode(toolsMessage)

		let (_, toolsResp) = try await postSession.data(for: toolsReq)
		#expect((toolsResp as! HTTPURLResponse).statusCode == 202)

		try await Task.sleep(for: .milliseconds(500))

		// Ping
		let pingMessage = JSONRPCMessage.request(id: 3, method: "ping")
		var pingReq = URLRequest(url: messagesURL)
		pingReq.httpMethod = "POST"
		pingReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		pingReq.httpBody = try encode(pingMessage)

		let (_, pingResp) = try await postSession.data(for: pingReq)
		#expect((pingResp as! HTTPURLResponse).statusCode == 202)

		try await Task.sleep(for: .milliseconds(500))

		sseTask.cancel()

		// Verify tools/list response
		let allDataEvents = receivedEvents.value.filter { $0.event != "endpoint" }
		let toolsEvent = allDataEvents.first { event in
			guard let msg = try? decode(Data(event.data.utf8)),
				  case .response(let r) = msg, r.id == .int(2) else { return false }
			return true
		}
		#expect(toolsEvent != nil, "Expected tools/list response via SSE")

		if let event = toolsEvent {
			let message = try decode(Data(event.data.utf8))
			guard case .response(let resp) = message,
				  let result = resp.result,
				  let tools = result["tools"] else {
				Issue.record("Expected tools in response")
				return
			}
			guard case .array(let toolArray) = tools else {
				Issue.record("Expected tools array")
				return
			}
			#expect(!toolArray.isEmpty, "Calculator should have tools")
		}

		// Verify ping response
		let pingEvent = allDataEvents.first { event in
			guard let msg = try? decode(Data(event.data.utf8)),
				  case .response(let r) = msg, r.id == .int(3) else { return false }
			return true
		}
		#expect(pingEvent != nil, "Expected ping response via SSE")
		#endif
	}

	/// POSTs an initialize request to the given legacy messages URL and returns the status and body.
	private func postInitialize(to messagesURL: URL) async throws -> (status: Int, body: String?) {
		var req = URLRequest(url: messagesURL)
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req.httpBody = try encode(initializeRequest())
		let (body, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
		return ((resp as! HTTPURLResponse).statusCode, String(data: body, encoding: .utf8))
	}

	/// Checks that a POST for an unknown session id returns 404 and creates nothing.
	@Test("Legacy SSE: POST to an unknown session returns 404")
	func legacySSEUnknownSessionRejected() async throws {
		#if canImport(FoundationNetworking)
		// The test does not run on Linux.
		return
		#else
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let result = try await postInitialize(to: baseURL.appendingPathComponent("messages/\(UUID().uuidString)"))
		#expect(result.status == 404)
		#expect(result.body == "Unknown session.")
		#expect(await transport.sessionManager.sessions.isEmpty)
		#endif
	}

	#if canImport(Darwin)
	/// Opens GET /sse on a raw socket and returns the socket plus the messages URL from the endpoint event.
	private func openLegacySSESocket(baseURL: URL, extraHeaders: String = "") throws -> (fd: Int32, messagesURL: URL) {
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		#expect(fd >= 0)
		var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var addr = sockaddr_in()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = in_port_t(UInt16(baseURL.port!).bigEndian)
		addr.sin_addr.s_addr = inet_addr("127.0.0.1")
		let connected = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		#expect(connected == 0)
		let request = "GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\(extraHeaders)\r\n"
		_ = request.withCString { send(fd, $0, strlen($0), 0) }

		var received = ""
		var buffer = [UInt8](repeating: 0, count: 4096)
		let deadline = Date().addingTimeInterval(2)
		func endpointLine() -> String? {
			received.components(separatedBy: "\n").dropLast().first { $0.hasPrefix("data: ") && $0.contains("/messages/") }
		}
		while Date() < deadline, endpointLine() == nil {
			let n = recv(fd, &buffer, buffer.count, 0)
			if n > 0 { received += String(decoding: buffer[0..<n], as: UTF8.self) }
		}
		let endpointLine = endpointLine()
		let messagesURL = endpointLine.flatMap { URL(string: String($0.dropFirst("data: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)) }
		guard let messagesURL else {
			close(fd)
			throw TestError.noEndpoint(received)
		}
		return (fd, messagesURL)
	}

	/// The error thrown when the SSE handshake delivers no endpoint event.
	private enum TestError: Error { case noEndpoint(String) }
	#endif

	/// Checks that a POST after the stream closed returns 404 and does not recreate the session.
	@Test("Legacy SSE: POST after the stream closed returns 404")
	func legacySSEClosedSessionRejected() async throws {
		#if canImport(FoundationNetworking)
		// The test does not run on Linux.
		return
		#else
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let (fd, messagesURL) = try openLegacySSESocket(baseURL: baseURL)
		#expect(await transport.sessionManager.sessions.count == 1)

		// The transport drops the session once the stream closes.
		close(fd)
		let deadline = Date().addingTimeInterval(5)
		while Date() < deadline, await !transport.sessionManager.sessions.isEmpty {
			try await Task.sleep(for: .milliseconds(100))
		}
		#expect(await transport.sessionManager.sessions.isEmpty)

		let result = try await postInitialize(to: messagesURL)
		#expect(result.status == 404)
		#expect(result.body == "Unknown session.")
		#expect(await transport.sessionManager.sessions.isEmpty)
		#endif
	}

	/// Checks that the legacy stream starts a new session even when the request names an existing one.
	@Test("Legacy SSE: a supplied session ID is ignored")
	func legacySSEIgnoresSuppliedSessionID() async throws {
		#if canImport(FoundationNetworking)
		// The test does not run on Linux.
		return
		#else
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let (first, firstURL) = try openLegacySSESocket(baseURL: baseURL)
		defer { close(first) }
		let existingID = firstURL.lastPathComponent
		let (second, secondURL) = try openLegacySSESocket(baseURL: baseURL, extraHeaders: "Mcp-Session-Id: \(existingID)\r\n")
		defer { close(second) }

		#expect(secondURL.lastPathComponent != existingID)
		#expect(await transport.sessionManager.sessions.count == 2)
		#endif
	}

	/// Checks that a streamable GET naming an unknown session gets 404.
	@Test("GET /mcp: an unknown session ID returns 404")
	func streamUnknownSessionRejected() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		var request = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		request.setValue(UUID().uuidString, forHTTPHeaderField: "Mcp-Session-Id")
		let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
		#expect((response as? HTTPURLResponse)?.statusCode == 404)
		#expect(await transport.sessionManager.sessions.isEmpty)
	}

	/// Checks that a second stream for a session that already has one gets 409.
	@Test("GET /mcp: a second stream for a session returns 409")
	func secondStreamRejected() async throws {
		#if canImport(FoundationNetworking)
		// URLSession.bytes(for:) is unavailable on Linux FoundationNetworking.
		return
		#else
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }
		let session = URLSession(configuration: .ephemeral)

		var initialize = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		initialize.httpMethod = "POST"
		initialize.setValue("application/json", forHTTPHeaderField: "Content-Type")
		initialize.setValue("application/json", forHTTPHeaderField: "Accept")
		initialize.httpBody = try encode(initializeRequest())
		let (_, initialized) = try await session.data(for: initialize)
		let sessionID = try #require((initialized as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id"))

		var stream = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		stream.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		stream.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
		// A task holds the first stream open.
		let streamRequest = stream
		let firstStream = Task { _ = try await URLSession(configuration: .ephemeral).bytes(for: streamRequest) }
		defer { firstStream.cancel() }
		try await Task.sleep(for: .milliseconds(300))

		let (_, second) = try await session.data(for: stream)
		#expect((second as? HTTPURLResponse)?.statusCode == 409)
		#endif
	}

	#if canImport(Darwin)
	/// Counts the pings that arrive on an open SSE socket during the given number of seconds.
	private func countPings(fd: Int32, seconds: TimeInterval) -> Int {
		var received = ""
		var buffer = [UInt8](repeating: 0, count: 4096)
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			let n = recv(fd, &buffer, buffer.count, 0)
			if n > 0 { received += String(decoding: buffer[0..<n], as: UTF8.self) }
		}
		return received.components(separatedBy: "\"method\":\"ping\"").count - 1
	}
	#endif

	/// Checks that an open SSE stream receives pings at an interval set after start.
	@Test("Legacy SSE: pings arrive at an interval set after start")
	func legacySSEKeepAliveIntervalAfterStart() async throws {
		#if canImport(FoundationNetworking)
		// The test does not run on Linux.
		return
		#else
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }
		transport.keepAliveInterval = 0.2

		let (fd, _) = try openLegacySSESocket(baseURL: baseURL)
		defer { close(fd) }
		let pings = countPings(fd: fd, seconds: 1.5)
		#expect(pings >= 3, "Expected at least 3 pings in 1.5 s at a 0.2 s interval, got \(pings)")
		#endif
	}

	/// Checks that an open SSE stream receives pings at an interval set before start.
	@Test("Legacy SSE: pings arrive at an interval set before start")
	func legacySSEKeepAliveIntervalBeforeStart() async throws {
		#if canImport(FoundationNetworking)
		// The test does not run on Linux.
		return
		#else
		let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
		transport.keepAliveInterval = 0.2
		try await transport.start()
		defer { Task { try? await transport.stop() } }
		let baseURL = URL(string: "http://127.0.0.1:\(transport.port)")!

		let (fd, _) = try openLegacySSESocket(baseURL: baseURL)
		defer { close(fd) }
		let pings = countPings(fd: fd, seconds: 1.5)
		#expect(pings >= 3, "Expected at least 3 pings in 1.5 s at a 0.2 s interval, got \(pings)")
		#endif
	}

	/// Checks that a keep-alive interval of zero or less leaves the previous value in place.
	@Test("Keep-alive interval ignores zero and negative values")
	func keepAliveIntervalIgnoresNonPositive() async throws {
		let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
		transport.keepAliveInterval = 5
		transport.keepAliveInterval = 0
		#expect(transport.keepAliveInterval == 5)
		transport.keepAliveInterval = -1
		#expect(transport.keepAliveInterval == 5)
		try await transport.stop()
	}

	// MARK: - DELETE /mcp

	@Test("DELETE /mcp: removes session")
	func deleteSession() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		let url = baseURL.appendingPathComponent("mcp")

		// Initialize to create a session
		var initReq = URLRequest(url: url)
		initReq.httpMethod = "POST"
		initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
		initReq.setValue("application/json", forHTTPHeaderField: "Accept")
		initReq.httpBody = try encode(initializeRequest())

		let (_, initResp) = try await session.data(for: initReq)
		let sessionId = (initResp as! HTTPURLResponse).value(forHTTPHeaderField: "Mcp-Session-Id")!

		// DELETE /mcp to remove the session
		var deleteReq = URLRequest(url: url)
		deleteReq.httpMethod = "DELETE"
		deleteReq.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")

		let (_, deleteResp) = try await session.data(for: deleteReq)
		#expect((deleteResp as! HTTPURLResponse).statusCode == 204)
	}

	// MARK: - CORS

	@Test("OPTIONS returns CORS headers when origins are allowed")
	func corsHeaders() async throws {
		let (transport, baseURL) = try await startTransport()
		transport.allowedOrigins = ["http://localhost:3000"]
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		var request = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		request.httpMethod = "OPTIONS"

		let (_, response) = try await session.data(for: request)
		let http = response as! HTTPURLResponse
		#expect(http.statusCode == 200)
		#expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Methods")?.contains("POST") == true)
		#expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Headers")?.contains("Content-Type") == true)
		#expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Headers")?.contains("Mcp-Session-Id") == true)
	}

	/// Checks that OPTIONS answers 204 with no CORS headers when no origins are allowed.
	@Test("OPTIONS returns no CORS headers by default")
	func corsHeadersOffByDefault() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		var request = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		request.httpMethod = "OPTIONS"

		let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
		let http = response as! HTTPURLResponse
		#expect(http.statusCode == 204)
		#expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
	}

	// MARK: - OpenAPI

	@Test("GET /.well-known/ai-plugin.json returns manifest when serveOpenAPI is true")
	func aiPluginManifest() async throws {
		let server = Calculator()
		let transport = HTTPSSETransport(server: server, host: "127.0.0.1", port: 0)
		transport.serveOpenAPI = true
		try await transport.start()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		let url = URL(string: "http://127.0.0.1:\(transport.port)/.well-known/ai-plugin.json")!

		let (data, response) = try await session.data(from: url)
		let http = response as! HTTPURLResponse
		#expect(http.statusCode == 200)

		let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
		#expect(json["name_for_model"] as? String == "calculator")
		let api = json["api"] as? [String: Any]
		#expect((api?["url"] as? String)?.hasSuffix("/openapi.json") == true)
	}

	@Test("GET /.well-known/ai-plugin.json returns 404 when serveOpenAPI is false")
	func aiPluginManifestDisabled() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		let url = URL(string: "\(baseURL.absoluteString)/.well-known/ai-plugin.json")!

		let (_, response) = try await session.data(from: url)
		#expect((response as! HTTPURLResponse).statusCode == 404)
	}

	@Test("GET /openapi.json returns spec with tool paths")
	func openAPISpec() async throws {
		let server = Calculator()
		let transport = HTTPSSETransport(server: server, host: "127.0.0.1", port: 0)
		transport.serveOpenAPI = true
		try await transport.start()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		let url = URL(string: "http://127.0.0.1:\(transport.port)/openapi.json")!

		let (data, response) = try await session.data(from: url)
		let http = response as! HTTPURLResponse
		#expect(http.statusCode == 200)

		let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
		#expect(json["openapi"] as? String == "3.1.0")

		let info = json["info"] as? [String: Any]
		#expect(info?["title"] as? String == "Calculator")

		// Should have paths for Calculator tools
		let paths = json["paths"] as? [String: Any]
		#expect(paths?["/calculator/add"] != nil, "Expected /calculator/add path")
	}

	@Test("POST /{serverName}/{toolName} calls tool and returns result")
	func openAPIToolCall() async throws {
		let server = Calculator()
		let transport = HTTPSSETransport(server: server, host: "127.0.0.1", port: 0)
		transport.serveOpenAPI = true
		try await transport.start()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		let url = URL(string: "http://127.0.0.1:\(transport.port)/calculator/add")!

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONSerialization.data(withJSONObject: ["a": 3, "b": 7])

		let (data, response) = try await session.data(for: request)
		let http = response as! HTTPURLResponse
		#expect(http.statusCode == 200)

		// The result should contain 10 (3 + 7)
		let body = String(data: data, encoding: .utf8) ?? ""
		#expect(body.contains("10"), "Expected result to contain 10, got: \(body)")
	}

	/// Checks that a failed OpenAPI tool call answers with only the error message.
	@Test("POST /{serverName}/{toolName}: errors carry no internal details")
	func openAPIToolCallErrorIsPlain() async throws {
		let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
		transport.serveOpenAPI = true
		try await transport.start()
		defer { Task { try? await transport.stop() } }

		var request = URLRequest(url: URL(string: "http://127.0.0.1:\(transport.port)/calculator/noSuchTool")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = Data("{}".utf8)

		let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
		#expect((response as? HTTPURLResponse)?.statusCode == 404)

		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		let error = json?["error"] as? [String: Any]
		#expect(error?["message"] is String)
		#expect(error?["data"] == nil)
	}

	// MARK: - Error cases

	/// Checks that requests failing authorization leave no session behind.
	@Test("Failed authorization stores no session")
	func failedAuthorizationStoresNoSession() async throws {
		let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
		transport.authorizationHandler = { _ in .unauthorized("No token") }
		try await transport.start()
		defer { Task { try? await transport.stop() } }
		let baseURL = URL(string: "http://127.0.0.1:\(transport.port)")!
		let session = URLSession(configuration: .ephemeral)

		var post = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		post.httpMethod = "POST"
		post.setValue("application/json", forHTTPHeaderField: "Content-Type")
		post.setValue("application/json", forHTTPHeaderField: "Accept")
		post.httpBody = try encode(initializeRequest())
		let (_, postResponse) = try await session.data(for: post)
		#expect((postResponse as? HTTPURLResponse)?.statusCode == 401)

		var sse = URLRequest(url: baseURL.appendingPathComponent("sse"))
		sse.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		let (_, sseResponse) = try await session.data(for: sse)
		#expect((sseResponse as? HTTPURLResponse)?.statusCode == 401)

		#expect(await transport.sessionManager.sessions.isEmpty)
	}

	/// Checks that a rejected token sent with an open session's ID leaves that session in place.
	@Test("Failed authorization keeps an existing session")
	func failedAuthorizationKeepsExistingSession() async throws {
		let transport = HTTPSSETransport(server: Calculator(), host: "127.0.0.1", port: 0)
		transport.authorizationHandler = { $0 == "good" ? .authorized : .unauthorized("Bad token") }
		try await transport.start()
		defer { Task { try? await transport.stop() } }
		let session = URLSession(configuration: .ephemeral)

		var request = URLRequest(url: URL(string: "http://127.0.0.1:\(transport.port)/mcp")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue("Bearer good", forHTTPHeaderField: "Authorization")
		request.httpBody = try encode(initializeRequest())
		let (_, first) = try await session.data(for: request)
		let sessionID = try #require((first as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id"))

		request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
		request.setValue("Bearer bad", forHTTPHeaderField: "Authorization")
		let (_, second) = try await session.data(for: request)
		#expect((second as? HTTPURLResponse)?.statusCode == 401)
		#expect(await transport.sessionManager.existingSession(id: try #require(UUID(uuidString: sessionID))) != nil)
	}

	/// Checks that a new session past the cap gets a 503 and the open sessions stay.
	@Test("POST /mcp: a session past the cap returns 503")
	func sessionCapRefusesNewSessions() async throws {
		let (transport, baseURL) = try await startTransport()
		transport.maxSessions = 1
		defer { Task { try? await transport.stop() } }
		let session = URLSession(configuration: .ephemeral)

		var request = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.httpBody = try encode(initializeRequest())

		let (_, first) = try await session.data(for: request)
		#expect((first as? HTTPURLResponse)?.statusCode == 200)

		let (_, second) = try await session.data(for: request)
		#expect((second as? HTTPURLResponse)?.statusCode == 503)
		#expect(await transport.sessionManager.sessions.count == 1)
	}

	@Test("POST /mcp: missing body returns 400")
	func missingBody() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		var request = URLRequest(url: baseURL.appendingPathComponent("mcp"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		// No body

		let (_, response) = try await session.data(for: request)
		#expect((response as! HTTPURLResponse).statusCode == 400)
	}

	@Test("GET /sse: wrong Accept header returns 400")
	func wrongAcceptHeader() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		var request = URLRequest(url: baseURL.appendingPathComponent("sse"))
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		let (_, response) = try await session.data(for: request)
		#expect((response as! HTTPURLResponse).statusCode == 400)
	}

	@Test("unknown path returns 404")
	func unknownPath() async throws {
		let (transport, baseURL) = try await startTransport()
		defer { Task { try? await transport.stop() } }

		let session = URLSession(configuration: .ephemeral)
		let (_, response) = try await session.data(from: baseURL.appendingPathComponent("nonexistent"))
		#expect((response as! HTTPURLResponse).statusCode == 404)
	}
}


/// Thread-safe box for capturing values from @Sendable closures.
private final class Box<T: Sendable>: @unchecked Sendable {
	var value: T
	init(_ value: T) { self.value = value }
}

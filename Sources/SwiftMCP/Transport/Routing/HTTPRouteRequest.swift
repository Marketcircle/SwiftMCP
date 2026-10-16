import Foundation

/// A transport-agnostic HTTP request.
///
/// The `Body` generic parameter determines whether the request body is buffered (`Data?`)
/// or streaming (`AsyncStream<Data>`).
public struct HTTPRouteRequest<Body: Sendable>: Sendable {

	/// The HTTP method.
	public let method: RouteMethod

	/// The raw URI string (path + query string).
	public let uri: String

	/// The path component of the URI (without query string).
	public let path: String

	/// HTTP headers as name-value pairs.
	public let headers: [(String, String)]

	/// The request body — `Data?` for buffered handlers, `AsyncStream<Data>` for streaming handlers.
	public let body: Body

	/// Path parameters extracted from `:segments` in the route pattern.
	/// For example, route `/files/:id` matched against `/files/abc` yields `["id": "abc"]`.
	public let pathParams: [String: String]

	/// Query parameters from the URI. Array of tuples to support duplicate keys.
	/// For example, `?tag=a&tag=b` yields `[("tag", "a"), ("tag", "b")]`.
	public let queryParams: [(String, String)]

	/// The record of why a streamed body ended early, filled in by the HTTP handler.
	var bodyCutoff: BodyCutoff? = nil

	// MARK: - Convenience

	/// Extracts the Bearer token from the Authorization header, if present.
	public var bearerToken: String? {
		guard let auth = header("Authorization") else { return nil }
		let prefix = "Bearer "
		guard auth.hasPrefix(prefix) else { return nil }
		return String(auth.dropFirst(prefix.count))
	}

	/// Extracts the session ID from the `Mcp-Session-Id` header, if present.
	public var sessionID: String? {
		header("Mcp-Session-Id")
	}

	/// Returns the first header value matching the given name (case-insensitive).
	public func header(_ name: String) -> String? {
		headers.first(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame })?.1
	}
}

/// A record of why a streamed request body ended early.
final class BodyCutoff: @unchecked Sendable {
	/// A reason a streamed body ends early.
	enum Reason: Sendable {
		/// The body passed its size limit.
		case tooLarge
		/// The client disconnected before the body ended.
		case disconnected
		/// The body went quiet for longer than the read timeout.
		case timedOut
	}

	/// The lock that guards ``storedReason``.
	private let lock = NSLock()
	/// The backing value of ``reason``.
	private var storedReason: Reason?

	/// The reason the body ended early, or `nil` if the body arrived whole.
	var reason: Reason? {
		lock.withLock { storedReason }
	}

	/// Records the reason the body ended early, keeping the first one.
	func record(_ reason: Reason) {
		lock.withLock {
			if storedReason == nil {
				storedReason = reason
			}
		}
	}
}

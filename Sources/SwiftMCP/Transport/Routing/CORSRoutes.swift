import Foundation


/// CORS preflight route handler.
extension HTTPSSETransport {

	/// Returns the CORS preflight route (`OPTIONS *`).
	///
	/// Only emits CORS headers when ``allowedOrigins`` is configured.
	func corsRoutes() -> [HTTPRoute] {
		[
			HTTPRoute(
				method: .OPTIONS,
				pathPattern: "/*",
				handler: { (transport: HTTPSSETransport, _: HTTPRouteRequest<Data?>) in
					guard let origin = transport.allowedOrigins?.first, !origin.isEmpty else {
						return RouteResponse(status: .noContent)
					}
					return RouteResponse(status: .ok, headers: [
						("Access-Control-Allow-Origin", origin),
						("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
						("Access-Control-Allow-Headers", "Content-Type, Content-Disposition, Authorization, MCP-Protocol-Version, Mcp-Session-Id"),
					])
				}
			)
		]
	}
}

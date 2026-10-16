import Foundation

extension AsyncStream<Data>: RouteBody {
	/// Forward the stream as-is — no buffering.
	static func collect(from stream: AsyncStream<Data>) async -> AsyncStream<Data> {
		stream
	}

	/// A Boolean value indicating whether the handler gets the whole body at once.
	static var isBuffered: Bool { false }
}

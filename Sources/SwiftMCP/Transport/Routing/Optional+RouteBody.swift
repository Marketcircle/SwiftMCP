import Foundation

extension Optional: RouteBody where Wrapped == Data {
	/// Collect all chunks into a single `Data?` value.
	static func collect(from stream: AsyncStream<Data>) async -> Data? {
		var collected = Data()
		for await chunk in stream {
			collected.append(chunk)
		}
		return collected.isEmpty ? nil : collected
	}

	/// A Boolean value indicating whether the handler gets the whole body at once, which is true for collected data.
	static var isBuffered: Bool { true }
}
